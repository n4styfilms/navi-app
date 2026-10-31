import Foundation
import CoreFoundation
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase

/// Application-owned model. It accepts copies from the existing location service;
/// it neither creates a GPS provider nor depends on a route or visible map.
@MainActor final class FriendsRuntime {
  enum RuntimeError: Error { case unavailable, alreadyConfigured, signedIn, invalidName, persistence }
  struct Fix: Sendable {
    let measuredAtDeviceMs: Int64
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
    let metersPerSecond: Double?
    let bearingDegrees: Double?
  }
  struct Snapshot {
    let configured: Bool
    let accountState: FriendsAccountController.State
    let sharingState: FriendsSharingController.State
    let uid: String
    let ownName: String
    let peers: [FriendsRepository.Peer]
    let requests: [String]
    let grants: [String: FriendsRepository.Grant]
    let signingOut: Bool
    let pendingRevocations: Bool
    let lastError: String?
  }
  @MainActor final class Observation {
    private var remove: (() -> Void)?
    fileprivate init(_ remove: @escaping () -> Void) { self.remove = remove }
    func close() { let action = remove; remove = nil; action?() }
  }

  private static let configurationKey = "navi-friends-configuration"
  private let preferences: UserDefaults
  private let transport: FriendsDataSession.Transport
  private var identity: FirebaseApp?
  private var auth: Auth?
  private var ownsIdentity = false
  private var accounts: FriendsAccountController?
  private var session: FriendsDataSession?
  private var repository: FriendsRepository?
  private var sharing: FriendsSharingController?
  private var logout: FriendsSignOutCoordinator?
  private var peerObservation: FriendsObservation?
  private var subscriptions: [FriendsSubscription] = []
  private var observers: [UUID: (Snapshot) -> Void] = [:]
  private var emission: UInt64 = 0
  private var closed = false
  private var signingOut = false
  private var accountState: FriendsAccountController.State = .signedOut
  private var sharingState: FriendsSharingController.State = .off
  private var acknowledgedLocationDemand = false
  private var peers: [FriendsRepository.Peer] = []
  private var ownName = ""
  private var requests: [String] = []
  private var grants: [String: FriendsRepository.Grant] = [:]
  private var pendingOwners = Set<String>()
  private var lastFailure: Error?
  private var anchorServerMs: Int64 = 0
  private var anchorUptime: TimeInterval = 0
  private var sharingStartedUptime: TimeInterval = 0
  private var sharingStartedDeviceMs: Int64 = 0
  private var lastDeviceFixMs: Int64 = 0
  private var sequence: Int64 = 0
  private var mapVisible = false

  init(preferences: UserDefaults, transport: @escaping FriendsDataSession.Transport = { _, _ in }) throws {
    self.preferences = preferences
    self.transport = transport
    if let saved = preferences.data(forKey: Self.configurationKey) {
      do { try configure(json: saved) } catch { lastFailure = error }
    }
  }

  /// Borrowed identity for native emulator tests; the owner controls its lifecycle.
  init(identityApp: FirebaseApp, preferences: UserDefaults,
       transport: @escaping FriendsDataSession.Transport) throws {
    self.preferences = preferences
    self.transport = transport
    try attach(identityApp, owns: false)
  }

  private var ready: Bool {
    !closed && !signingOut && accountState == .ready && session?.isClosed == false
  }
  var projectID: String? { identity?.options.projectID }
  var snapshot: Snapshot {
    .init(configured: !closed && identity != nil, accountState: accountState, sharingState: sharingState,
      uid: ready ? session!.owner : "", ownName: ready ? ownName : "",
      peers: ready ? peers : [], requests: ready ? requests : [], grants: ready ? grants : [:],
      signingOut: signingOut, pendingRevocations: !pendingOwners.isEmpty, lastError: lastFailure?.localizedDescription)
  }
  var locationDemand: Bool {
    ready && acknowledgedLocationDemand && serverNowMs > 0
      && (sharingState == .sharing || sharingState == .reconnecting)
  }
  var serverNowMs: Int64 {
    guard anchorServerMs > 0 else { return 0 }
    let elapsed = (ProcessInfo.processInfo.systemUptime - anchorUptime) * 1000
    guard elapsed.isFinite, elapsed >= 0, elapsed < 9_007_199_254_740_991 else { return 0 }
    let result = anchorServerMs.addingReportingOverflow(Int64(elapsed))
    return !result.overflow && result.partialValue <= 9_007_199_254_740_991 ? result.partialValue : 0
  }
  func setMapVisible(_ visible: Bool) { mapVisible = visible }

  func observe(_ changed: @escaping (Snapshot) -> Void) -> Observation {
    let id = UUID()
    if !closed { observers[id] = changed }
    changed(snapshot)
    return Observation { [weak self] in self?.observers.removeValue(forKey: id) }
  }
  private func emit() {
    emission += 1
    let ticket = emission, value = snapshot
    for observer in Array(observers.values) {
      guard emission == ticket else { break }
      observer(value)
    }
  }

  func configure(json: Data) throws {
    guard !closed, identity == nil else { throw RuntimeError.alreadyConfigured }
    let config = try FriendsGroupConfiguration(json: json)
    let name = "navi-friends-identity"
    guard FirebaseApp.app(name: name) == nil else { throw RuntimeError.alreadyConfigured }
    let options = FirebaseOptions(googleAppID: config.applicationID, gcmSenderID: config.senderID)
    options.projectID = config.projectID
    options.apiKey = config.apiKey
    options.databaseURL = config.databaseURL.absoluteString
    options.bundleID = Bundle.main.bundleIdentifier ?? "app.navi.private"
    FirebaseApp.configure(name: name, options: options)
    guard let app = FirebaseApp.app(name: name) else { throw RuntimeError.unavailable }
    do {
      try attach(app, owns: true)
      preferences.set(try config.encoded(), forKey: Self.configurationKey)
      guard preferences.synchronize() else { throw RuntimeError.persistence }
    } catch {
      accounts?.close(); accounts = nil; clearData()
      identity = nil; auth = nil; ownsIdentity = false
      app.delete { _ in }
      throw error
    }
    lastFailure = nil; emit()
  }

  private func attach(_ app: FirebaseApp, owns: Bool) throws {
    let primary = Auth.auth(app: app)
    if owns {
      let database = Database.database(app: app)
      database.isPersistenceEnabled = false
      try transport(primary, database)
    }
    identity = app; auth = primary; ownsIdentity = owns
    pendingOwners = Set(preferences.stringArray(forKey: pendingKey(app)) ?? [])
    let useTransport = transport
    accounts = FriendsAccountController(auth: primary, opener: { user in
      try await FriendsDataSession.open(identityApp: app, user: user, transport: useTransport)
    }, listener: { [weak self] state, opened, error in
      guard let self, !self.closed else { return }
      self.clearData()
      self.accountState = state; self.lastFailure = error
      if state == .ready, let opened {
        do { try self.openData(opened) }
        catch { opened.close(); self.clearData(); self.accountState = .error; self.lastFailure = error }
      }
      self.emit()
    })
    emit()
  }

  private func pendingKey(_ app: FirebaseApp) -> String { "navi-friends-pending/" + app.options.googleAppID }
  private func markPending(_ owner: String, _ pending: Bool) throws {
    guard let identity else { throw RuntimeError.unavailable }
    if pending { pendingOwners.insert(owner) } else { pendingOwners.remove(owner) }
    preferences.set(pendingOwners.sorted(), forKey: pendingKey(identity))
    guard preferences.synchronize() else { throw RuntimeError.persistence }
  }

  private func openData(_ opened: FriendsDataSession) throws {
    session = opened
    let repo = try FriendsRepository(session: opened, now: { [weak self] in self?.serverNowMs ?? 0 })
    repository = repo
    subscriptions.append(try opened.listen("profiles/\(opened.owner)", onValue: { [weak self] data in
      guard let self, !self.closed, self.session === opened, !self.signingOut else { return }
      self.ownName = data.childSnapshot(forPath: "displayName").value as? String ?? ""
      self.emit()
    }, onCancel: { [weak self] error in self?.receive(error, from: opened) }))
    subscriptions.append(try opened.listen(".info/serverTimeOffset", onValue: { [weak self] data in
      guard let self, !self.closed, self.session === opened, !self.signingOut,
            let offset = data.value as? NSNumber, CFGetTypeID(offset) != CFBooleanGetTypeID() else { return }
      let timestamp = Date().timeIntervalSince1970 * 1000 + offset.doubleValue
      guard timestamp.isFinite, timestamp > 0, timestamp <= 9_007_199_254_740_991 else {
        self.anchorServerMs = 0; self.emit(); return
      }
      self.anchorServerMs = Int64(timestamp); self.anchorUptime = ProcessInfo.processInfo.systemUptime
      self.emit()
    }, onCancel: { [weak self] error in self?.receive(error, from: opened) }))
    sharing = try FriendsSharingController(session: opened, repository: repo, preferences: preferences,
      now: { [weak self] in self?.serverNowMs ?? 0 }, changed: { [weak self] state in
        guard let self, !self.closed, self.session === opened else { return }
        self.sharingState = state
        // Keep the existing background wake source across temporary network loss.
        // Initial enable/reopen still needs its own server ACK; pause/error clears it.
        if state != .reconnecting { self.acknowledgedLocationDemand = state == .sharing }
        self.sharingStartedUptime = state == .sharing ? ProcessInfo.processInfo.systemUptime : 0
        self.sharingStartedDeviceMs = state == .sharing ? Int64(Date().timeIntervalSince1970 * 1000) : 0
        if state == .paused, self.pendingOwners.contains(opened.owner) {
          do { try self.markPending(opened.owner, false) } catch { self.lastFailure = error }
        }
        self.emit()
      })
    peerObservation = try repo.observe { [weak self] values in
      guard let self, !self.closed, self.session === opened, !self.signingOut else { return }
      self.peers = values; self.emit()
    }
    subscriptions.append(try opened.listen("requests/\(opened.owner)", onValue: { [weak self] data in
      guard let self, !self.closed, self.session === opened, !self.signingOut else { return }
      self.requests = data.children.compactMap { ($0 as? DataSnapshot)?.key }.sorted(); self.emit()
    }, onCancel: { [weak self] error in self?.receive(error, from: opened) }))
    subscriptions.append(try opened.listen("grants/\(opened.owner)", onValue: { [weak self] data in
      guard let self, !self.closed, self.session === opened, !self.signingOut else { return }
      var values: [String: FriendsRepository.Grant] = [:]
      for case let child as DataSnapshot in data.children {
        values[child.key] = .init(position: child.childSnapshot(forPath: "position").value as? Bool == true,
          speed: child.childSnapshot(forPath: "speed").value as? Bool == true,
          trips: child.childSnapshot(forPath: "trips").value as? Bool == true)
      }
      self.grants = values; self.emit()
    }, onCancel: { [weak self] error in self?.receive(error, from: opened) }))
  }
  private func receive(_ error: Error, from opened: FriendsDataSession) {
    guard session === opened, !closed, !signingOut else { return }
    lastFailure = error; emit()
  }
  private func clearViewData() {
    peerObservation?.close(); peerObservation = nil
    subscriptions.forEach { $0.close() }; subscriptions.removeAll()
    peers = []; requests = []; grants = [:]; ownName = ""; anchorServerMs = 0
  }
  private func clearData() {
    session = nil
    logout?.close(); logout = nil
    sharing?.close(); sharing = nil; repository = nil
    clearViewData()
    sharingState = .off; acknowledgedLocationDemand = false; signingOut = false
    sharingStartedUptime = 0; sharingStartedDeviceMs = 0; lastDeviceFixMs = 0; sequence = 0
  }

  func register(email: String, password: String) async throws {
    guard !closed, !signingOut, let auth else { throw RuntimeError.unavailable }
    guard auth.currentUser == nil else { throw RuntimeError.signedIn }
    _ = try await auth.createUser(withEmail: email, password: password)
  }
  func signIn(email: String, password: String) async throws {
    guard !closed, !signingOut, let auth else { throw RuntimeError.unavailable }
    guard auth.currentUser == nil else { throw RuntimeError.signedIn }
    _ = try await auth.signIn(withEmail: email, password: password)
  }
  private func currentRepository() throws -> FriendsRepository {
    guard ready, let repository else { throw RuntimeError.unavailable }
    return repository
  }
  func request(_ uid: String) async throws { try await currentRepository().requestFriend(uid) }
  func confirm(_ uid: String) async throws { try await currentRepository().confirmFriend(uid) }
  func grant(_ uid: String, grant: FriendsRepository.Grant) async throws {
    try await currentRepository().setGrant(uid, grant: grant)
  }
  func remove(_ uid: String) async throws { try await currentRepository().removeFriend(uid) }
  func setName(_ name: String) async throws {
    guard ready, let session else { throw RuntimeError.unavailable }
    guard !name.isEmpty, name.utf16.count <= 40,
          name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw RuntimeError.invalidName }
    try await session.database().reference(withPath: "profiles/\(session.owner)").setValue(["displayName": name])
  }
  func setSharing(_ enabled: Bool) async throws {
    guard ready, let sharing, !enabled || serverNowMs > 0 else { throw RuntimeError.unavailable }
    try await sharing.setEnabled(enabled)
  }

  func acceptLocation(_ fix: Fix) async throws -> Bool {
    guard ready, let sharing, sharingState == .sharing, sharingStartedUptime > 0,
          fix.measuredAtDeviceMs > sharingStartedDeviceMs, fix.measuredAtDeviceMs > lastDeviceFixMs,
          sequence < 9_007_199_254_740_991 else { return false }
    let deviceNow = Int64(Date().timeIntervalSince1970 * 1000)
    let age = deviceNow.subtractingReportingOverflow(fix.measuredAtDeviceMs)
    guard !age.overflow, age.partialValue >= 0, age.partialValue <= 15_000 else { return false }
    let fixUptime = ProcessInfo.processInfo.systemUptime - Double(age.partialValue) / 1000
    let timestamp = serverNowMs
    guard fixUptime >= sharingStartedUptime, timestamp > age.partialValue else { return false }
    let sample = PresenceSample(sequence: sequence + 1, measuredAtMs: timestamp - age.partialValue,
      latitude: fix.latitude, longitude: fix.longitude, accuracyMeters: fix.accuracyMeters,
      metersPerSecond: fix.metersPerSecond, bearingDegrees: fix.bearingDegrees)
    guard sample.isValid else { return false }
    lastDeviceFixMs = fix.measuredAtDeviceMs; sequence += 1
    return try await sharing.accept(sample, foregroundMap: mapVisible,
      moving: sample.speedMetersPerSecond.map { $0 >= 0.5 } ?? true)
  }

  func signOut() async throws -> FriendsSignOutCoordinator.Outcome {
    guard !closed, let accounts else { throw RuntimeError.unavailable }
    guard let sharing else {
      var persistenceFailure: Error?
      if let user = auth?.currentUser, let identity {
        do {
          try FriendsSharingController.persistPendingRevocation(preferences: preferences,
            applicationID: identity.options.googleAppID, owner: user.uid)
          try markPending(user.uid, true)
        } catch { persistenceFailure = error }
      }
      try accounts.signOut()
      if let persistenceFailure { lastFailure = persistenceFailure; emit(); throw persistenceFailure }
      return pendingOwners.isEmpty ? .acknowledged : .pending
    }
    if logout == nil {
      logout = FriendsSignOutCoordinator(sharing: sharing, clearPeerData: { [weak self] in
        guard let self else { return }
        self.signingOut = true
        if let owner = self.session?.owner {
          do { try self.markPending(owner, true) } catch { self.lastFailure = error }
        }
        self.clearViewData(); self.emit()
      }, signOut: { [weak accounts] in try accounts?.signOut() })
    }
    let coordinator = logout!
    return try await coordinator.signOut()
  }

  func close() {
    guard !closed else { return }
    closed = true
    accounts?.close(); accounts = nil
    clearData(); accountState = .closed
    if ownsIdentity { identity?.delete { _ in } }
    identity = nil; auth = nil
    emit(); observers.removeAll()
  }
}
