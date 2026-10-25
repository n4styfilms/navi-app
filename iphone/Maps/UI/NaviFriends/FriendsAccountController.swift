import Foundation
import FirebaseAuth

/// Account changes invalidate pending work before any new data connection is exposed.
@MainActor final class FriendsAccountController {
  enum State: Equatable { case signedOut, loading, ready, error, closed }
  typealias Opener = @MainActor (User) async throws -> FriendsDataSession
  typealias Listener = @MainActor (State, FriendsDataSession?, Error?) -> Void

  private let auth: Auth
  private let opener: Opener
  private let listener: Listener
  private var authListener: NSObjectProtocol?
  private var generation: UInt64 = 0
  private var account: String?
  private var observed = false
  private var closed = false
  private(set) var session: FriendsDataSession?
  private(set) var state: State = .signedOut

  init(auth: Auth, opener: @escaping Opener, listener: @escaping Listener) {
    self.auth = auth
    self.opener = opener
    self.listener = listener
    authListener = auth.addStateDidChangeListener { [weak self] _, _ in
      Task { @MainActor in self?.accountChanged() }
    }
  }

  private func notify(_ state: State, error: Error? = nil) {
    self.state = state
    listener(state, session, error)
  }

  private func clearSession() {
    let previous = session
    session = nil
    previous?.close()
  }

  private func accountChanged() {
    guard !closed else { return }
    let user = auth.currentUser
    let uid = user?.uid
    guard !observed || account != uid else { return }
    observed = true
    account = uid
    generation += 1
    let ticket = generation
    clearSession()
    guard !closed, ticket == generation else { return }
    guard let user else { notify(.signedOut); return }
    notify(.loading)
    // UI callbacks may synchronously sign out or close the controller.
    guard !closed, ticket == generation else { return }
    let open = opener
    Task { [weak self] in
      do {
        let opened = try await open(user)
        guard let self, !self.closed, ticket == self.generation,
              self.auth.currentUser?.uid == uid else {
          opened.close()
          return
        }
        guard !opened.isClosed, opened.owner == uid else {
          opened.close()
          self.notify(.error, error: FriendsDataSession.SessionError.accountCopyFailed)
          return
        }
        self.session = opened
        self.notify(.ready)
      } catch {
        guard let self, !self.closed, ticket == self.generation,
              self.auth.currentUser?.uid == uid else { return }
        self.notify(.error, error: error)
      }
    }
  }

  /// Local identity/session cleanup only. The runtime must first coordinate server revocation.
  func signOut() throws {
    guard !closed else { return }
    generation += 1
    account = nil
    observed = true
    clearSession()
    do { try auth.signOut() }
    catch {
      // Ignore queued notifications for the identity whose logout failed. Never
      // reopen its data session merely because the SDK still retains that user.
      account = auth.currentUser?.uid
      if !closed { notify(.error, error: error) }
      throw error
    }
    if !closed { notify(.signedOut) }
  }

  func close() {
    guard !closed else { return }
    closed = true
    generation += 1
    if let authListener { auth.removeStateDidChangeListener(authListener) }
    authListener = nil
    clearSession()
    notify(.closed)
  }
}
