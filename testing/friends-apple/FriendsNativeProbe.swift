import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase

enum ProbeError: Error { case failed(String) }

@MainActor enum FriendsNativeProbe {
  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.failed(message) }
  }

  static func waitFor(_ label: String, _ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(15)
    while !condition() {
      if Date() >= end { throw ProbeError.failed("Timed out: " + label) }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  static func identity(_ label: String) async throws -> (FirebaseApp, User) {
    let options = FirebaseOptions(googleAppID: "1:1234567890:ios:abcdef0123456789", gcmSenderID: "1234567890")
    options.projectID = "demo-navi-friends"
    options.apiKey = "fake-api-key"
    options.databaseURL = "https://demo-navi-friends.firebaseio.com"
    options.bundleID = "app.navi.friendstest"
    let name = "navi-apple-identity-" + UUID().uuidString
    FirebaseApp.configure(name: name, options: options)
    let app = FirebaseApp.app(name: name)!
    let auth = Auth.auth(app: app)
    auth.useEmulator(withHost: "127.0.0.1", port: 9099)
    let result = try await auth.createUser(withEmail: label + UUID().uuidString + "@example.test", password: "synthetic-local-password-123")
    return (app, result.user)
  }

  static let local: FriendsDataSession.Transport = { auth, database in
    auth.useEmulator(withHost: "127.0.0.1", port: 9099)
    database.useEmulator(withHost: "127.0.0.1", port: 9000)
  }

  static func run() async throws {
    let (aliceApp, alice) = try await identity("alice")
    let (bobApp, bob) = try await identity("bob")
    let (chrisApp, chris) = try await identity("chris")
    let aliceData = try await FriendsDataSession.open(identityApp: aliceApp, user: alice, transport: local)
    let bobData = try await FriendsDataSession.open(identityApp: bobApp, user: bob, transport: local)
    defer { aliceData.close(); bobData.close() }
    try check(aliceData.owner == alice.uid && bobData.owner == bob.uid, "Copied auth owner mismatch")
    let cloned = Auth.auth(app: FirebaseApp.app(name: bobData.appName)!)
    let token = try await cloned.currentUser!.getIDToken(forcingRefresh: true)
    try check(!token.isEmpty, "Copied native auth cannot refresh")
    let a = try aliceData.database().reference()
    let b = try bobData.database().reference()
    try await a.child("friendConsent/\(alice.uid)/\(bob.uid)").setValue(true)
    try await b.child("friendConsent/\(bob.uid)/\(alice.uid)").setValue(true)
    try await a.child("grants/\(alice.uid)/\(bob.uid)").setValue(["position": true, "speed": false, "trips": false])
    try await a.child("liveControl/\(alice.uid)").setValue(["enabled": true, "generation": 1])
    let position: [String: Any] = ["sequence": 1, "sharingGeneration": 1, "latitude": 43.7295,
      "longitude": 7.4208, "accuracyMeters": 4, "measuredAtMs": Int64(Date().timeIntervalSince1970 * 1000),
      "receivedAtMs": ServerValue.timestamp()]
    try await a.updateChildValues(["live/\(alice.uid)/position": position,
                                  "liveControl/\(alice.uid)/publishedSequence": 1])
    print("native_apple_auth_cloned=true")

    var values = 0
    var cancelled = false
    let observation = try bobData.listen("live/\(alice.uid)/position", onValue: { snapshot in
      if snapshot.exists() { values += 1 }
    }, onCancel: { _ in cancelled = true })
    try await waitFor("initial authorized position", { values > 0 })
    try await a.child("liveControl/\(alice.uid)").setValue(["enabled": false, "generation": 2])
    try await waitFor("server listener revocation", { cancelled })
    let countAtRevocation = values
    try await Task.sleep(nanoseconds: 200_000_000)
    try check(values == countAtRevocation, "Values delivered after server revocation")
    observation.close()
    print("native_apple_listener_revoked=true")

    var cleared = false
    _ = bobData.onClose { cleared = true }
    bobData.close()
    try check(cleared && bobData.isClosed && Auth.auth(app: bobApp).currentUser?.uid == bob.uid,
              "Session close did not clear immediately or signed out primary identity")
    let chrisData = try await FriendsDataSession.open(identityApp: chrisApp, user: chris, transport: local)
    defer { chrisData.close() }
    var oldPeerValues = 0
    var denied = false
    let deniedObservation = try chrisData.listen("live/\(alice.uid)/position", onValue: { _ in oldPeerValues += 1 },
                                               onCancel: { _ in denied = true })
    try await waitFor("fresh account denied old peer", { denied })
    try check(oldPeerValues == 0, "Fresh account inherited another account's cached peer")
    deniedObservation.close()
    print("native_apple_fresh_session_denied_old_peer=true")
    print("NAVI_APPLE_NATIVE_SUCCESS proofs=3")
    for app in [aliceApp, bobApp, chrisApp] {
      try Auth.auth(app: app).signOut()
      app.delete { _ in }
    }
  }
}
