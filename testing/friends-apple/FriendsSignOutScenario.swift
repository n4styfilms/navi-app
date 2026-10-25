import Foundation
import FirebaseAuth
import FirebaseDatabase

@MainActor enum FriendsSignOutScenario {
  static func run() async throws {
    let (app, user) = try await FriendsNativeProbe.identity("logout")
    defer { app.delete { _ in } }
    let auth = Auth.auth(app: app)
    var current: FriendsDataSession?
    let accounts = FriendsAccountController(auth: auth, opener: {
      try await FriendsDataSession.open(identityApp: app, user: $0, transport: FriendsNativeProbe.local)
    }, listener: { _, session, _ in current = session })
    defer { accounts.close() }
    try await FriendsNativeProbe.waitFor("logout account ready", { current != nil })
    let data = current!
    let audit = try await FriendsDataSession.open(identityApp: app, user: user, transport: FriendsNativeProbe.local)
    defer { audit.close() }
    let control = try audit.database().reference(withPath: "liveControl/\(user.uid)")
    let suite = "navi-logout-probe-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let now = { Int64(Date().timeIntervalSince1970 * 1000) }
    // Fresh local settings must still revoke an older server-side enable on logout.
    try await data.database().reference(withPath: "liveControl/\(user.uid)").setValue(["enabled": true, "generation": 1])
    let repository = try FriendsRepository(session: data, now: now)
    let sharing = try FriendsSharingController(session: data, repository: repository,
      preferences: preferences, now: now, changed: { _ in })
    defer { sharing.close() }
    try await FriendsNativeProbe.waitFor("logout sharing connection", { sharing.isConnected })
    try FriendsNativeProbe.check(sharing.state == .off, "Fresh local settings did not start OFF")
    var cleared = false
    let logout = FriendsSignOutCoordinator(sharing: sharing, clearPeerData: { cleared = true },
      signOut: { try accounts.signOut() })
    defer { logout.close() }
    let online = Task { try await logout.signOut() }
    try await FriendsNativeProbe.waitFor("logout clears peers immediately", { cleared })
    let onlineResult = try await online.value
    try FriendsNativeProbe.check(onlineResult == .acknowledged && data.isClosed && auth.currentUser == nil,
      "Online logout did not revoke before account closure")
    let disabled = try await control.getData()
    try FriendsNativeProbe.check(disabled.childSnapshot(forPath: "enabled").value as? Bool == false,
      "Online logout left server sharing enabled")
    print("native_apple_online_logout=true")

    try await auth.signIn(withEmail: user.email!, password: "synthetic-local-password-123")
    try await FriendsNativeProbe.waitFor("offline logout account ready", { current != nil })
    let offlineData = current!
    let offlineRepo = try FriendsRepository(session: offlineData, now: now)
    let offlineSharing = try FriendsSharingController(session: offlineData, repository: offlineRepo,
      preferences: preferences, now: now, changed: { _ in })
    defer { offlineSharing.close() }
    try await FriendsNativeProbe.waitFor("offline logout connection", { offlineSharing.isConnected })
    try await offlineSharing.setEnabled(true)
    let enabled = try await control.getData()
    try FriendsNativeProbe.check(enabled.childSnapshot(forPath: "enabled").value as? Bool == true,
      "Offline logout setup never enabled server sharing")
    try offlineData.database().goOffline()
    try await FriendsNativeProbe.waitFor("offline logout disconnected", { offlineSharing.state == .reconnecting })
    cleared = false
    let offlineLogout = FriendsSignOutCoordinator(sharing: offlineSharing, clearPeerData: { cleared = true },
      signOut: { try accounts.signOut() })
    defer { offlineLogout.close() }
    let started = Date()
    let offline = Task { try await offlineLogout.signOut() }
    try await FriendsNativeProbe.waitFor("offline logout clears peers", { cleared })
    let offlineResult = try await offline.value
    let elapsed = Date().timeIntervalSince(started)
    try FriendsNativeProbe.check(offlineResult == .pending && offlineData.isClosed && auth.currentUser == nil
      && elapsed >= 4.8 && elapsed < 10, "Offline logout did not finish with bounded pending revocation")
    let stillEnabled = try await control.getData()
    try FriendsNativeProbe.check(stillEnabled.childSnapshot(forPath: "enabled").value as? Bool == true,
      "Offline logout test did not preserve its unacknowledged server state")
    try await auth.signIn(withEmail: user.email!, password: "synthetic-local-password-123")
    try await FriendsNativeProbe.waitFor("pending logout re-login", { current != nil })
    let resumedData = current!
    let resumedRepo = try FriendsRepository(session: resumedData, now: now)
    let resumed = try FriendsSharingController(session: resumedData, repository: resumedRepo,
      preferences: preferences, now: now, changed: { _ in })
    defer { resumed.close() }
    try await FriendsNativeProbe.waitFor("pending logout finishes on re-login", { resumed.state == .paused })
    let finallyDisabled = try await control.getData()
    try FriendsNativeProbe.check(finallyDisabled.childSnapshot(forPath: "enabled").value as? Bool == false
      && !finallyDisabled.hasChild("publishedSequence"), "Re-login failed to finish pending server revocation")
    print("native_apple_offline_logout=true")
  }
}
