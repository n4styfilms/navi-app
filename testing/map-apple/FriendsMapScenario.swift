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
        {"version":8,"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
         "sources":{},"layers":[{"id":"paper","type":"background","paint":{"background-color":"#e6eee2"}}]}
        """.utf8)
    } else if url.path == "/fonts/Noto Sans Regular/0-255.pbf" {
      data = try! Data(contentsOf: Bundle.main.url(forResource: "noto-0-255", withExtension: "pbf")!)
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
    try await wait("actual rendered glyphs", { query().contains { $0.attribute(forKey: "uid") as? String == marker.uid } })
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
    print("NAVI_FRIENDS_MAP_SUCCESS rendered-label style-reload freshness removal camera-preserved")
  }
}
