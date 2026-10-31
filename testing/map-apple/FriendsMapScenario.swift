import UIKit
import MapLibre

/// Actual shipping renderer with deterministic public-resource responses, no account or live friends.
final class FriendsMapResources: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    let data: Data
    if url.path == "/styles/liberty" {
      data = Data("""
        {"version":8,
         "sources":{},"layers":[{"id":"paper","type":"background","paint":{"background-color":"#e6eee2"}}]}
        """.utf8)
    } else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
      httpVersion: "HTTP/1.1", headerFields: ["Content-Type": url.path.hasSuffix("pbf") ? "application/x-protobuf" : "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor enum FriendsMapScenario {
  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "FriendsMapScenario", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]) }
  }
  static func wait(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try require(false, "Timed out: " + message)
  }
  static func run(in host: UIViewController) async throws {
    let owner = NaviMapController(frame: host.view.bounds,
      configuration: NaviEsriConfiguration(key: "", language: "en"),
      testProtocolClasses: [FriendsMapResources.self])
    defer { owner.close(); owner.view.removeFromSuperview() }
    host.view.addSubview(owner.view)
    owner.view.setCenter(CLLocationCoordinate2D(latitude: 43.7295, longitude: 7.4208), zoomLevel: 15, animated: false)
    let marker = NaviFriendMarker(uid: "synthetic-peer", latitude: 43.7295, longitude: 7.4208,
      label: "Test friend · 32 km/h", stale: false)
    owner.setFriends([marker]) // Cache before style loading, without a route.
    owner.setBasemap(.street)
    try await wait("initial friends layer", { owner.view.style?.source(withIdentifier: "navi-friends") != nil })
    let camera = owner.view.camera.copy() as! MLNMapCamera
    let query = { owner.view.visibleFeatures(in: owner.view.bounds,
      styleLayerIdentifiers: Set(["navi-friends-label"])) }
    try await wait("actual rendered caption", { query().contains { $0.attribute(forKey: "uid") as? String == marker.uid } })
    try require(query().first?.attribute(forKey: "label") as? String == marker.label, "Rendered label lost speed")
    try require(owner.geometryRevision == nil, "Friends created route geometry")
    owner.retry()
    try await wait("style reload", { owner.view.style?.name == "navi-style-2" && !query().isEmpty })
    try require(owner.view.camera == camera, "Friends or style reload moved the camera")
    let stale = NaviFriendMarker(uid: marker.uid, latitude: marker.latitude, longitude: marker.longitude,
      label: "Test friend · Last position", stale: true)
    owner.setFriends([stale])
    try await wait("stale speed removed", { query().first?.attribute(forKey: "label") as? String == stale.label })
    UIGraphicsBeginImageContextWithOptions(host.view.bounds.size, true, 0)
    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    let image = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext()
    let document = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try image?.pngData()?.write(to: document.appendingPathComponent("friends-map.png"))
    owner.setFriends([])
    try await wait("revoked marker removed", { query().isEmpty })
    try require(owner.view.camera == camera, "Revocation moved camera")
    let distant = NaviFriendMarker(uid: marker.uid, latitude: marker.latitude + 0.01, longitude: marker.longitude,
      label: "Test friend", stale: false)
    owner.setFriends([distant]); owner.setFollowing(true)
    try require(!owner.focusFriend("unavailable") && owner.view.camera == camera,
      "Missing friend changed the camera")
    try require(owner.focusFriend(marker.uid), "Visible friend cannot be focused")
    try await wait("explicit friend focus", { abs(owner.view.centerCoordinate.latitude - distant.latitude) < 0.000001 })
    owner.setLocation(CLLocation(latitude: marker.latitude + 0.1, longitude: marker.longitude))
    try await Task.sleep(nanoseconds: 800_000_000)
    try require(abs(owner.view.centerCoordinate.latitude - distant.latitude) < 0.000001,
      "Own GPS immediately stole the selected friend's camera")
    print("NAVI_FRIENDS_MAP_SUCCESS rendered-label style-reload freshness removal camera-preserved explicit-focus")
  }
}
