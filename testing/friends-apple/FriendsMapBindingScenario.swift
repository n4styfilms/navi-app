import UIKit
import MapLibre
import FirebaseAuth

@MainActor enum FriendsMapBindingScenario {
  static func run() async throws {
    guard let window = (UIApplication.shared.delegate as? FriendsProbeApp)?.window,
          let host = window.rootViewController else { throw ProbeError.failed("No map fixture window") }
    let (sourceApp, sourceUser) = try await FriendsNativeProbe.identity("map-source")
    let (receiverApp, receiverUser) = try await FriendsNativeProbe.identity("map-receiver")
    defer { for app in [sourceApp, receiverApp] { try? Auth.auth(app: app).signOut(); app.delete { _ in } } }
    let suite = "navi-map-binding-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = try FriendsRuntime(identityApp: sourceApp, preferences: preferences, transport: FriendsNativeProbe.local)
    let receiver = try FriendsRuntime(identityApp: receiverApp, preferences: preferences, transport: FriendsNativeProbe.local)
    defer { source.close(); receiver.close() }
    try await FriendsNativeProbe.waitFor("map accounts and clocks", {
      source.snapshot.accountState == .ready && receiver.snapshot.accountState == .ready
        && source.serverNowMs > 0 && receiver.serverNowMs > 0
    })
    let owner = NaviMapController(frame: host.view.bounds,
      configuration: NaviEsriConfiguration(key: "", language: "en"), testProtocolClasses: [FriendsMapResources.self])
    host.view.addSubview(owner.view)
    defer { owner.close(); owner.view.removeFromSuperview() }
    owner.view.setCenter(CLLocationCoordinate2D(latitude: 43.7295, longitude: 7.4208), zoomLevel: 15, animated: false)
    let camera = owner.view.camera.copy() as! MLNMapCamera
    let observation = receiver.observe { value in
      owner.setFriends(FriendsMapProjection.markers(from: value.peers, at: receiver.serverNowMs))
    }
    defer { observation.close() }
    owner.setBasemap(.street)
    try await FriendsNativeProbe.waitFor("actual map style", { owner.state.snapshot.status == .ready })
    let rendered = { owner.view.visibleFeatures(in: owner.view.bounds,
      styleLayerIdentifiers: Set(["navi-friends-label"])) }
    try await source.setName("Map peer")
    try await source.request(receiverUser.uid)
    try await FriendsNativeProbe.waitFor("map request", { receiver.snapshot.requests.contains(sourceUser.uid) })
    try FriendsNativeProbe.check(rendered().isEmpty, "Unconfirmed request rendered a friend")
    try await receiver.confirm(sourceUser.uid)
    try await source.grant(receiverUser.uid, grant: .init(position: true, speed: true, trips: false))
    try await source.setSharing(true)
    try await Task.sleep(nanoseconds: 2_000_000)
    let sent = try await source.acceptLocation(.init(measuredAtDeviceMs: Int64(Date().timeIntervalSince1970 * 1000),
      latitude: 43.7295, longitude: 7.4208, accuracyMeters: 4, metersPerSecond: 9, bearingDegrees: 180))
    try FriendsNativeProbe.check(sent, "Map source fix not published")
    try await FriendsNativeProbe.waitFor("SDK point rendered with speed", {
      rendered().contains { $0.attribute(forKey: "uid") as? String == sourceUser.uid
        && ($0.attribute(forKey: "label") as? String)?.contains("32 km/h") == true }
    })
    try FriendsSheetScenario.capture(window, name: "friends-map-live.png")
    owner.retry()
    try await FriendsNativeProbe.waitFor("SDK marker survives style", {
      owner.view.style?.name == "navi-style-2" && !rendered().isEmpty
    })
    owner.setFriends(FriendsMapProjection.markers(from: receiver.snapshot.peers, at: receiver.serverNowMs + 16_001))
    try await FriendsNativeProbe.waitFor("map speed expires", {
      !rendered().isEmpty && rendered().allSatisfy { ($0.attribute(forKey: "label") as? String)?.contains("km/h") == false }
    })
    try FriendsSheetScenario.capture(window, name: "friends-map-stale.png")
    try await source.grant(receiverUser.uid, grant: .init(position: true, speed: false, trips: false))
    try await FriendsNativeProbe.waitFor("speed right revoked but position retained", {
      receiver.snapshot.peers.first?.speedAllowed == false && receiver.snapshot.peers.first?.position != nil
        && rendered().first?.attribute(forKey: "label") as? String == "Map peer"
    })
    try await source.grant(receiverUser.uid, grant: .init(position: false, speed: false, trips: false))
    try await FriendsNativeProbe.waitFor("position revoked removes rendered marker", { rendered().isEmpty })
    try FriendsNativeProbe.check(owner.view.camera == camera && owner.geometryRevision == nil,
      "SDK friend changes moved camera or created route geometry")
    try await source.setSharing(false)
    print("native_apple_map_binding=true")
  }
}
