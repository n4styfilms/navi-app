import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase

/// One account's disposable data connection. Peer values are never persisted to disk.
/// Closing is local cleanup; sharing revocation still requires a separate server ACK.
@MainActor final class FriendsDataSession {
  typealias Transport = (Auth, Database) throws -> Void
  enum SessionError: Error { case closed, accountCopyFailed }

  let owner: String
  var appName: String { app.name }
  private(set) var isClosed = false
  private(set) var cleanupError: Error?
  private let app: FirebaseApp
  private let auth: Auth
  private let connection: Database
  private var databaseUsed = false
  private var registrations: [UUID: FriendsSubscription] = [:]
  private var closeObservers: [UUID: () -> Void] = [:]

  private init(app: FirebaseApp, auth: Auth, database: Database, owner: String) {
    self.app = app
    self.auth = auth
    connection = database
    self.owner = owner
  }

  static func open(identityApp: FirebaseApp, user: User,
                   transport: Transport = { _, _ in }) async throws -> FriendsDataSession {
    let name = "navi-friends-data-" + UUID().uuidString
    FirebaseApp.configure(name: name, options: identityApp.options)
    let app = FirebaseApp.app(name: name)!
    let auth = Auth.auth(app: app)
    let database = Database.database(app: app)
    database.isPersistenceEnabled = false
    let session = FriendsDataSession(app: app, auth: auth, database: database, owner: user.uid)
    do {
      try transport(auth, database)
      try await auth.updateCurrentUser(user)
      guard auth.currentUser?.uid == user.uid else { throw SessionError.accountCopyFailed }
      return session
    } catch {
      session.close()
      throw error
    }
  }

  func database() throws -> Database {
    guard !isClosed else { throw SessionError.closed }
    databaseUsed = true
    return connection
  }

  func listen(_ path: String, onValue: @escaping (DataSnapshot) -> Void,
              onCancel: @escaping (Error) -> Void) throws -> FriendsSubscription {
    let reference = try database().reference(withPath: path)
    let id = UUID()
    let subscription = FriendsSubscription { [weak self] in self?.registrations.removeValue(forKey: id) }
    registrations[id] = subscription
    let handle = reference.observe(.value, with: { [weak self, weak subscription] snapshot in
      Task { @MainActor in
        guard let self, !self.isClosed, let subscription, !subscription.isClosed else { return }
        onValue(snapshot)
      }
    }, withCancel: { [weak self, weak subscription] error in
      Task { @MainActor in
        guard let self, !self.isClosed, let subscription, !subscription.isClosed else { return }
        onCancel(error)
      }
    })
    subscription.detach = { reference.removeObserver(withHandle: handle) }
    return subscription
  }

  @discardableResult func onClose(_ observer: @escaping () -> Void) -> FriendsSubscription {
    if isClosed { observer(); return FriendsSubscription {} }
    let id = UUID()
    closeObservers[id] = observer
    return FriendsSubscription { [weak self] in self?.closeObservers.removeValue(forKey: id) }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    let active = Array(registrations.values)
    registrations.removeAll()
    active.forEach { $0.close() }
    let observers = Array(closeObservers.values)
    closeObservers.removeAll()
    observers.forEach { $0() }
    // Avoid initializing an unused SDK Repo just before deleting its Auth app.
    if databaseUsed {
      connection.purgeOutstandingWrites()
      connection.goOffline()
    }
    do { try auth.signOut() } catch { cleanupError = error }
    app.delete { _ in }
  }
}

@MainActor final class FriendsSubscription {
  private(set) var isClosed = false
  fileprivate var detach: (() -> Void)?
  private var remove: (() -> Void)?
  fileprivate init(_ remove: @escaping () -> Void) { self.remove = remove }
  func close() {
    guard !isClosed else { return }
    isClosed = true
    detach?()
    detach = nil
    remove?()
    remove = nil
  }
}
