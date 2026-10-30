import Foundation
import FirebaseAuth
import FirebaseDatabase

/// A location-state change must not discard an unrelated queued profile write
/// when this controller has no pending presence publication or lease transaction.
@MainActor enum FriendsPendingWriteScenario {
  static func run() async throws {
    let (app, user) = try await FriendsNativeProbe.identity("pending-profile")
    defer { try? Auth.auth(app: app).signOut(); app.delete { _ in } }
    let data = try await FriendsDataSession.open(identityApp: app, user: user, transport: FriendsNativeProbe.local)
    defer { data.close() }
    let suite = "navi-pending-profile-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let repo = try FriendsRepository(session: data)
    let sharing = try FriendsSharingController(session: data, repository: repo,
      preferences: preferences, now: { Int64(Date().timeIntervalSince1970 * 1000) }, changed: { _ in })
    defer { sharing.close() }
    try await FriendsNativeProbe.waitFor("queued profile initial connection", { sharing.isConnected })
    try data.database().goOffline()
    try await FriendsNativeProbe.waitFor("queued profile offline", { !sharing.isConnected })
    var locallyQueued = false
    let profile = try data.listen("profiles/\(user.uid)", onValue: {
      locallyQueued = $0.childSnapshot(forPath: "displayName").value as? String == "Queued profile"
    }, onCancel: { _ in })
    defer { profile.close() }
    let write = Task { try await data.database().reference(withPath: "profiles/\(user.uid)")
      .setValue(["displayName": "Queued profile"]) }
    try await FriendsNativeProbe.waitFor("profile is queued locally before ACK", { locallyQueued })
    let enable = Task { try await sharing.setEnabled(true) }
    try await FriendsNativeProbe.waitFor("enable waiting for connection", { sharing.state == .enabling })
    try data.database().goOnline()
    try await enable.value
    try await write.value
    let audit = try await FriendsDataSession.open(identityApp: app, user: user, transport: FriendsNativeProbe.local)
    defer { audit.close() }
    let saved = try await audit.database().reference(withPath: "profiles/\(user.uid)").getData()
    try FriendsNativeProbe.check(saved.childSnapshot(forPath: "displayName").value as? String == "Queued profile",
      "Location enable lost an unrelated queued profile on the server")
    try await sharing.setEnabled(false)
    print("native_apple_pending_profile_preserved=true")
  }
}
