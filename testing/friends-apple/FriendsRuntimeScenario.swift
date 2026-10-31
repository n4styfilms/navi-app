import Foundation
import FirebaseCore
import FirebaseAuth
import CoreLocation

/// Application model boundary: actual Auth/DB clients, no navigation or map dependency.
@MainActor enum FriendsRuntimeScenario {
  static func run() async throws {
    print("native_apple_runtime_stage=unconfigured")
    let suite = "navi-runtime-probe-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let before = Set(FirebaseApp.allApps?.keys.map { $0 } ?? [])
    let groupSuite = suite + "-group"
    let groupPreferences = UserDefaults(suiteName: groupSuite)!
    defer { groupPreferences.removePersistentDomain(forName: groupSuite) }
    let empty = try FriendsRuntime(preferences: groupPreferences, transport: FriendsNativeProbe.local)
    try FriendsNativeProbe.check(!empty.snapshot.configured && empty.snapshot.peers.isEmpty
      && !empty.locationDemand, "Missing group configuration fabricated an account or sharing demand")
    let after = Set(FirebaseApp.allApps?.keys.map { $0 } ?? [])
    try FriendsNativeProbe.check(after.subtracting(before).isEmpty, "Unconfigured runtime initialized Firebase")
    let group = try JSONSerialization.data(withJSONObject: ["projectId": "demo-navi-friends",
      "applicationId": "1:1234567890:ios:abcdef0123456789", "apiKey": "fake-api-key",
      "databaseUrl": "https://demo-navi-friends.firebaseio.com"])
    print("native_apple_runtime_stage=configure")
    try empty.configure(json: group)
    print("native_apple_runtime_stage=register")
    try await empty.register(email: "runtime-group-" + UUID().uuidString + "@example.test",
      password: "synthetic-local-password-123")
    try await FriendsNativeProbe.waitFor("configured runtime registration", {
      empty.snapshot.configured && empty.snapshot.accountState == .ready && !empty.snapshot.uid.isEmpty
    })
    print("native_apple_runtime_stage=configured_logout")
    let configuredLogout = try await empty.signOut()
    try FriendsNativeProbe.check(configuredLogout == .acknowledged, "Configured runtime did not coordinate logout")
    empty.close()

    print("native_apple_runtime_stage=peer_accounts")
    let (sourceApp, sourceUser) = try await FriendsNativeProbe.identity("runtime-source")
    let (receiverApp, receiverUser) = try await FriendsNativeProbe.identity("runtime-receiver")
    let (strangerApp, strangerUser) = try await FriendsNativeProbe.identity("runtime-stranger")
    defer {
      for app in [sourceApp, receiverApp, strangerApp] { try? Auth.auth(app: app).signOut(); app.delete { _ in } }
    }
    let source = try FriendsRuntime(identityApp: sourceApp, preferences: preferences, transport: FriendsNativeProbe.local)
    let receiver = try FriendsRuntime(identityApp: receiverApp, preferences: preferences, transport: FriendsNativeProbe.local)
    defer { source.close(); receiver.close() }
    var providerDemands: [Bool] = []
    let bridge = FriendsLocationBridge(runtime: source, setDemand: { providerDemands.append($0) })
    defer { bridge.close() }
    try FriendsNativeProbe.check(providerDemands == [false], "Bridge requested GPS before acknowledged sharing")
    var observed: [FriendsRepository.Peer] = []
    let observation = receiver.observe { observed = $0.peers }
    defer { observation.close() }
    try await FriendsNativeProbe.waitFor("runtime accounts and server clocks", {
      source.snapshot.accountState == .ready && receiver.snapshot.accountState == .ready
        && source.serverNowMs > 0 && receiver.serverNowMs > 0
    })
    try await source.setName("Runtime source")
    try await source.request(receiverUser.uid)
    try await FriendsNativeProbe.waitFor("runtime incoming request", { receiver.snapshot.requests.contains(sourceUser.uid) })
    try FriendsNativeProbe.check(observed.isEmpty, "Unconfirmed request became a visible friend")
    try await receiver.confirm(sourceUser.uid)
    try await source.grant(receiverUser.uid, grant: .init(position: true, speed: true, trips: false))
    try await FriendsNativeProbe.waitFor("runtime confirmed peer", { observed.count == 1 })
    let beforeACK = Int64(Date().timeIntervalSince1970 * 1000) - 1
    print("native_apple_runtime_stage=sharing")
    try await source.setSharing(true)
    try FriendsNativeProbe.check(source.locationDemand, "Acknowledged sharing did not demand the existing provider")
    try FriendsNativeProbe.check(providerDemands == [false, true], "Bridge did not attach exactly once after ACK")
    let old = FriendsRuntime.Fix(measuredAtDeviceMs: beforeACK, latitude: 43.7295, longitude: 7.4208,
      accuracyMeters: 4, metersPerSecond: 10, bearingDegrees: 180)
    let replayed = try await source.acceptLocation(old)
    try FriendsNativeProbe.check(!replayed, "Runtime replayed a cached pre-ACK GPS fix")
    source.setMapVisible(true)
    let future = FriendsRuntime.Fix(measuredAtDeviceMs: Int64(Date().timeIntervalSince1970 * 1000) + 60_000,
      latitude: 43.7296, longitude: 7.4209, accuracyMeters: 5, metersPerSecond: 11, bearingDegrees: 181)
    let futureSent = try await source.acceptLocation(future)
    try FriendsNativeProbe.check(!futureSent, "Future GPS timestamp was accepted")
    try await Task.sleep(nanoseconds: 2_000_000)
    let fresh = FriendsRuntime.Fix(measuredAtDeviceMs: Int64(Date().timeIntervalSince1970 * 1000),
      latitude: 43.7296, longitude: 7.4209, accuracyMeters: 5, metersPerSecond: 11, bearingDegrees: 181)
    let deviceLocation = CLLocation(coordinate: CLLocationCoordinate2D(latitude: fresh.latitude, longitude: fresh.longitude),
      altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 181, speed: 11,
      timestamp: Date(timeIntervalSince1970: Double(fresh.measuredAtDeviceMs) / 1000))
    let unknownVelocity = CLLocation(coordinate: deviceLocation.coordinate, altitude: 0,
      horizontalAccuracy: 5, verticalAccuracy: 5, course: -1, speed: -1, timestamp: deviceLocation.timestamp)
    let copied = FriendsLocationBridge.copyFix(unknownVelocity)
    try FriendsNativeProbe.check(copied?.metersPerSecond == nil && copied?.bearingDegrees == nil
      && copied?.latitude == fresh.latitude && copied?.accuracyMeters == 5,
      "CoreLocation unknown speed/course became an invented measurement")
    bridge.onRawLocationUpdate(deviceLocation)
    try await FriendsNativeProbe.waitFor("runtime peer marker values without route", {
      observed.first?.displayName == "Runtime source"
        && observed.first?.speedMetersPerSecond(at: receiver.serverNowMs) == 11
    })
    let duplicate = try await source.acceptLocation(fresh)
    try FriendsNativeProbe.check(!duplicate, "Duplicate GPS fix was published twice")
    try await source.grant(receiverUser.uid, grant: .init(position: true, speed: false, trips: false))
    try await FriendsNativeProbe.waitFor("runtime independent speed revoke", {
      observed.first?.position != nil && observed.first?.speedAllowed == false
    })
    print("native_apple_runtime_stage=peer_logout")
    let result = try await receiver.signOut()
    try FriendsNativeProbe.check(result == .acknowledged && observed.isEmpty
      && receiver.snapshot.requests.isEmpty && !receiver.locationDemand,
      "Runtime logout retained foreign model values or provider demand")
    try await receiver.signIn(email: strangerUser.email!, password: "synthetic-local-password-123")
    try await FriendsNativeProbe.waitFor("runtime new account", {
      receiver.snapshot.accountState == .ready && receiver.snapshot.uid == strangerUser.uid
    })
    try await Task.sleep(nanoseconds: 200_000_000)
    try FriendsNativeProbe.check(observed.isEmpty && receiver.snapshot.requests.isEmpty,
      "New runtime account received old account's friend data")
    try await source.setSharing(false)
    try FriendsNativeProbe.check(!source.locationDemand, "Paused runtime retained location demand")
    try FriendsNativeProbe.check(providerDemands == [false, true, false], "Bridge retained provider demand on pause")
    print("native_apple_location_bridge=true")
    print("native_apple_runtime=true")
  }
}
