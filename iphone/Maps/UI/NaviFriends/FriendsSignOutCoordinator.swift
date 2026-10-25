import Foundation

/// Stops local peer display immediately, then gives server revocation a bounded
/// opportunity before closing the account. An offline outcome remains pending.
@MainActor final class FriendsSignOutCoordinator {
  enum Outcome: Equatable, Sendable { case acknowledged, pending }
  enum SignOutError: Error { case closed, superseded }
  private let sharing: FriendsSharingController
  private let clearPeerData: () -> Void
  private let closeAccount: () throws -> Void
  private var closed = false
  private var revision: UInt64 = 0
  private var waiters: [CheckedContinuation<Outcome, Error>] = []
  private var revocation: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private(set) var isSigningOut = false

  init(sharing: FriendsSharingController, clearPeerData: @escaping () -> Void,
       signOut: @escaping () throws -> Void) {
    self.sharing = sharing
    self.clearPeerData = clearPeerData
    closeAccount = signOut
  }

  func signOut() async throws -> Outcome {
    guard !closed else { throw SignOutError.closed }
    return try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
      guard !isSigningOut else { return }
      isSigningOut = true
      revision += 1
      let ticket = revision
      clearPeerData()
      // Clearing UI may synchronously close this coordinator or switch accounts.
      guard !closed, isSigningOut, revision == ticket else { return }
      if sharing.state == .paused {
        finish(ticket: ticket, outcome: .acknowledged)
        return
      }
      // OFF is merely local absence of intent. It does not prove the server is paused.
      let target = sharing
      revocation = Task { [weak self] in
        do {
          try await target.setEnabled(false)
          self?.finish(ticket: ticket, outcome: .acknowledged)
        } catch { self?.finish(ticket: ticket, outcome: .pending) }
      }
      timeout = Task { [weak self] in
        do { try await Task.sleep(nanoseconds: 5_000_000_000) }
        catch { return }
        self?.finish(ticket: ticket, outcome: .pending)
      }
    }
  }

  private func finish(ticket: UInt64, outcome: Outcome) {
    guard !closed, isSigningOut, revision == ticket else { return }
    isSigningOut = false
    revision += 1
    timeout?.cancel(); timeout = nil
    revocation?.cancel(); revocation = nil
    let pending = waiters; waiters.removeAll()
    do {
      // Account closure also closes sharing and resumes an offline pause waiter.
      // Its late completion cannot pass the invalidated coordinator revision.
      try closeAccount()
      pending.forEach { $0.resume(returning: outcome) }
    } catch { pending.forEach { $0.resume(throwing: error) } }
  }

  func close() {
    guard !closed else { return }
    closed = true; isSigningOut = false; revision += 1
    timeout?.cancel(); timeout = nil
    revocation?.cancel(); revocation = nil
    let pending = waiters; waiters.removeAll()
    pending.forEach { $0.resume(throwing: SignOutError.superseded) }
  }
}
