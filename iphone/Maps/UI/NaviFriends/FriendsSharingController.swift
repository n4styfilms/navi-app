import Foundation
import CoreFoundation
import FirebaseDatabase

/// Transaction blocks run on the SDK queue, not the main actor.
private final class FriendsSharingRevision: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0
  func advance() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
  func matches(_ ticket: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return value == ticket }
  static func integer(_ raw: Any?) -> Int64? {
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value.isFinite, value >= 1, value <= 9_007_199_254_740_991,
          value.rounded(.down) == value else { return nil }
    return Int64(value)
  }
}

/// Durable account-owned intent and server lease. Consumes the existing GPS stream only.
@MainActor final class FriendsSharingController {
  enum State: Equatable { case off, enabling, sharing, reconnecting, revocationPending, paused, error, closed }
  enum SharingError: Error { case closed, invalidSession, invalidLease, persistence, superseded }
  private struct Intent: Codable { var desired: Bool; var pending: Bool }
  static func persistPendingRevocation(preferences: UserDefaults, applicationID: String, owner: String) throws {
    let key = "navi-friends-sharing/" + applicationID + "/" + owner
    preferences.set(try JSONEncoder().encode(Intent(desired: false, pending: true)), forKey: key)
    guard preferences.synchronize() else { throw SharingError.persistence }
  }
  private let session: FriendsDataSession
  private let repository: FriendsRepository
  private let preferences: UserDefaults
  private let key: String
  private let now: () -> Int64
  private let changed: (State) -> Void
  private let gate = FriendsSharingRevision()
  private let policy = PresencePolicy()
  private var revision: UInt64 = 0
  private var hasIntent = false
  private var intent = Intent(desired: false, pending: false)
  private var closed = false
  private var inFlight = false
  private var pendingPresencePublications = 0
  private var lease: Int64 = 0
  private var policyTicket: UInt64 = 0
  private var completion: CheckedContinuation<Void, Error>?
  private var connection: FriendsSubscription?
  private var closing: FriendsSubscription?
  private(set) var state: State = .off
  private(set) var isConnected = false
  private(set) var lastFailure: Error?

  init(session: FriendsDataSession, repository: FriendsRepository, preferences: UserDefaults,
       now: @escaping () -> Int64, changed: @escaping (State) -> Void) throws {
    guard !session.isClosed, let app = try session.database().app else { throw SharingError.invalidSession }
    self.session = session
    self.repository = repository
    self.preferences = preferences
    self.now = now
    self.changed = changed
    key = "navi-friends-sharing/" + app.options.googleAppID + "/" + session.owner
    if let stored = preferences.data(forKey: key) {
      intent = try JSONDecoder().decode(Intent.self, from: stored)
      hasIntent = true
      // Reopening never reuses an earlier lease or its buffered location.
      if intent.desired { intent.pending = true; try persist() }
    }
    update(!hasIntent ? .off : intent.desired ? .reconnecting : intent.pending ? .revocationPending : .paused)
    closing = session.onClose { [weak self] in self?.accountClosed() }
    do {
      connection = try session.listen(".info/connected", onValue: { [weak self] snapshot in
        self?.connectionChanged(snapshot.value as? Bool == true)
      }, onCancel: { [weak self] error in self?.fail(error) })
    } catch { close(); throw error }
  }

  private func update(_ next: State) { state = next; changed(next) }
  private func persist() throws {
    // One record prevents a desired/pending pair from being saved inconsistently.
    preferences.set(try JSONEncoder().encode(intent), forKey: key)
    guard preferences.synchronize() else { throw SharingError.persistence }
  }
  private func finishWaiting(_ result: Result<Void, Error>) {
    let previous = completion; completion = nil
    previous?.resume(with: result)
  }
  private func invalidate() {
    // Starting from OFF must not cancel unrelated queued profile writes.
    // A pending lease or presence publication still needs cancellation on pause.
    let needsPurge = inFlight || pendingPresencePublications > 0
    revision = gate.advance()
    inFlight = false; lease = 0
    policy.pause()
    if needsPurge && !session.isClosed { try? session.database().purgeOutstandingWrites() }
  }

  func setEnabled(_ enabled: Bool) async throws {
    guard !closed else { throw SharingError.closed }
    invalidate()
    finishWaiting(.failure(SharingError.superseded))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      completion = continuation
      hasIntent = true
      intent = Intent(desired: enabled, pending: true)
      do { try persist() }
      catch { fail(error); return }
      update(enabled ? .enabling : .revocationPending)
      if isConnected { reconcile() }
    }
  }

  private func connectionChanged(_ online: Bool) {
    guard !closed, online != isConnected else { return }
    isConnected = online
    if online {
      if hasIntent && intent.pending { reconcile() }
      return
    }
    guard hasIntent, intent.desired || intent.pending else { return }
    invalidate()
    intent.pending = true
    do { try persist() } catch { fail(error); return }
    update(intent.desired ? .reconnecting : .revocationPending)
  }

  private func reconcile() {
    guard !closed, !session.isClosed, isConnected, intent.pending, !inFlight else { return }
    inFlight = true
    let ticket = revision, target = intent.desired, gate = gate
    do {
      try session.database().reference(withPath: "liveControl/\(session.owner)").runTransactionBlock({ data in
        guard gate.matches(ticket) else { return TransactionResult.abort() }
        let raw = data.childData(byAppendingPath: "generation").value
        let previous: Int64
        if raw == nil || raw is NSNull { previous = 0 }
        else if let value = FriendsSharingRevision.integer(raw), value < 9_007_199_254_740_991 { previous = value }
        else { return TransactionResult.abort() }
        // Replacing the node drops the old publication cursor with the old lease.
        data.value = ["enabled": target, "generation": previous + 1]
        return TransactionResult.success(withValue: data)
      }, andCompletionBlock: { [weak self] error, committed, snapshot in
        Task { @MainActor in self?.leaseFinished(ticket: ticket, target: target,
          error: error, committed: committed, snapshot: snapshot) }
      }, withLocalEvents: false)
    } catch { fail(error) }
  }

  private func leaseFinished(ticket: UInt64, target: Bool, error: Error?, committed: Bool, snapshot: DataSnapshot?) {
    guard !closed, ticket == revision else { return }
    inFlight = false
    if let error { fail(error); return }
    guard committed, let snapshot,
          let generation = FriendsSharingRevision.integer(snapshot.childSnapshot(forPath: "generation").value),
          snapshot.childSnapshot(forPath: "enabled").value as? Bool == target else {
      fail(SharingError.invalidLease); return
    }
    intent = Intent(desired: target, pending: false)
    do { try persist() } catch { fail(error); return }
    if target {
      lease = generation
      policyTicket = policy.begin(owner: session.owner, at: now())
      update(.sharing)
    } else {
      lease = 0; policy.pause(); update(.paused)
    }
    finishWaiting(.success(()))
  }

  func accept(_ sample: PresenceSample, foregroundMap: Bool, moving: Bool) async throws -> Bool {
    guard !closed, state == .sharing, lease > 0,
          let upload = policy.prepare(sample, at: now(), generation: policyTicket,
            foregroundMap: foregroundMap, moving: moving) else { return false }
    let ticket = revision
    pendingPresencePublications += 1
    defer { pendingPresencePublications -= 1 }
    do {
      try await repository.publish(policy: policy, upload: upload, lease: lease)
      return true
    } catch {
      if !closed && ticket == revision {
        intent = Intent(desired: false, pending: true)
        do { try persist() } catch { fail(error) }
        fail(error)
      }
      throw error
    }
  }

  private func fail(_ error: Error) {
    guard !closed else { return }
    lastFailure = error
    // Invalidate any transaction retry as well as local presence candidates.
    invalidate(); policy.fail()
    update(.error)
    finishWaiting(.failure(error))
  }
  private func accountClosed() {
    if hasIntent && intent.desired {
      intent = Intent(desired: false, pending: true)
      do { try persist() } catch { lastFailure = error }
    }
    close()
  }
  func close() {
    guard !closed else { return }
    closed = true
    revision = gate.advance(); policy.signOut(); lease = 0
    connection?.close(); connection = nil
    closing?.close(); closing = nil
    finishWaiting(.failure(SharingError.superseded))
    update(.closed)
  }
}
