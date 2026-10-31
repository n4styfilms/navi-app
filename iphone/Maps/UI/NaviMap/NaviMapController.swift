import UIKit
import CoreLocation
import MapLibre

/// Copied presentation values; the renderer has no account or database access.
struct NaviFriendMarker: Equatable {
  let uid: String
  let latitude: Double
  let longitude: Double
  let label: String
  let stale: Bool
}

/// MapLibre owns drawing only. The app's existing location manager and router supply copied values.
final class NaviMapController: NSObject, MLNMapViewDelegate {
  let view: MLNMapView
  let state: NaviMapLoadState
  var onState: ((NaviMapLoadState.Snapshot) -> Void)?
  var onViewportChanged: ((CLLocationCoordinate2D, Double) -> Void)?
  private let transport: NaviEsriTransport
  private var configuration: NaviEsriConfiguration
  private var mode: NaviBasemapMode = .street
  private var closed = false
  private var deadline: DispatchWorkItem?
  private var geometry: [CLLocationCoordinate2D] = []
  private(set) var geometryRevision: NSNumber?
  private var routeShape: MLNShape?
  private var target: CLLocationCoordinate2D?
  private var location: CLLocation?
  private var following = false
  private var routeSource: MLNShapeSource?
  private var targetSource: MLNShapeSource?
  private var positionSource: MLNShapeSource?
  private var friendsSource: MLNShapeSource?
  private var friends: [NaviFriendMarker] = []
  private var friendCaptions: [String: String] = [:]
  private var styleName: String?
  private static let blank = "{\"version\":8,\"name\":\"navi-setup\",\"sources\":{},\"layers\":[]}"

  init(frame: CGRect, configuration: NaviEsriConfiguration, testProtocolClasses: [AnyClass] = []) {
    precondition(Thread.isMainThread)
    self.configuration = configuration
    let policy = NaviMapLoadState()
    state = policy
    let loader = NaviEsriTransport(configuration: configuration, state: policy, testProtocolClasses: testProtocolClasses)
    transport = loader
    NaviEsriURLProtocol.install(loader)
    let network = URLSessionConfiguration.ephemeral
    network.protocolClasses = [NaviEsriURLProtocol.self]
    network.httpCookieStorage = nil
    network.urlCredentialStorage = nil
    network.urlCache = nil
    MLNNetworkConfiguration.sharedManager.sessionConfiguration = network
    MLNLoggingConfiguration.shared.loggingLevel = .none
    // A local empty setup style prevents the SDK from fetching its default demo map.
    view = MLNMapView(frame: frame, styleJSON: Self.blank)
    super.init()
    view.delegate = self
    view.showsUserLocation = false
    view.prefetchesTiles = false
    view.logoView.isHidden = false
    view.attributionButton.isHidden = false
    transport.onFailure = { [weak self] generation in
      DispatchQueue.main.async {
        guard let self, !self.closed, self.state.snapshot.generation == generation else { return }
        self.onState?(self.state.snapshot)
      }
    }
  }

  var requestCount: UInt64 { transport.requestCount }
  func setConfiguration(_ configuration: NaviEsriConfiguration) {
    precondition(Thread.isMainThread)
    self.configuration = configuration
    transport.configure(configuration)
    load()
  }
  func setBasemap(_ mode: NaviBasemapMode) {
    precondition(Thread.isMainThread)
    self.mode = mode
    load()
  }
  func retry() { load() }

  private func load() {
    precondition(Thread.isMainThread)
    guard !closed else { return }
    deadline?.cancel()
    let generation = state.begin(mode, configured: configuration.canLoad(mode))
    transport.cancelAll()
    styleName = nil
    routeSource = nil
    targetSource = nil
    positionSource = nil
    friendsSource = nil
    friendCaptions.removeAll()
    onState?(state.snapshot)
    guard configuration.canLoad(mode) else {
      view.styleJSON = Self.blank
      return
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, !self.closed, self.state.snapshot.generation == generation,
            self.state.snapshot.status == .loading else { return }
      self.transport.fail(generation, .styleError)
    }
    deadline = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: timeout)
    let url = configuration.styleURL(mode)
    transport.perform(URLRequest(url: url), generation: generation) { [weak self] result in
      guard case let .success((data, _)) = result else { return }
      DispatchQueue.main.async {
        guard let self, !self.closed, self.state.canRequest(generation) else { return }
        do {
          let name = "navi-style-\(generation)"
          let json = try Self.styleJSON(data, base: url, name: name)
          self.styleName = name
          // setStyle preserves the current camera. It must never build/fit a route.
          self.view.styleJSON = json
        } catch { self.transport.fail(generation, .styleError) }
      }
    }
  }

  /// A JSON string has no base URL in the SDK. Resolve only resource URL fields, retaining templates.
  private static func styleJSON(_ data: Data, base: URL, name: String) throws -> String {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["version"] as? Int == 8, root["sources"] is [String: Any], root["layers"] is [[String: Any]]
      else { throw NaviEsriTransport.failure() }
    func absolute(_ value: String) throws -> String {
      guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
            url.scheme == "https" else { throw NaviEsriTransport.failure() }
      return url.absoluteString.replacingOccurrences(of: "%7B", with: "{")
        .replacingOccurrences(of: "%7D", with: "}")
    }
    root["name"] = name
    for key in ["glyphs", "sprite"] {
      if let value = root[key] as? String { root[key] = try absolute(value) }
    }
    if var sprites = root["sprite"] as? [[String: Any]] {
      for index in sprites.indices {
        if let url = sprites[index]["url"] as? String { sprites[index]["url"] = try absolute(url) }
      }
      root["sprite"] = sprites
    }
    if var sources = root["sources"] as? [String: [String: Any]] {
      for key in Array(sources.keys) {
        if let url = sources[key]?["url"] as? String { sources[key]?["url"] = try absolute(url) }
        if let tiles = sources[key]?["tiles"] as? [String] { sources[key]?["tiles"] = try tiles.map(absolute) }
      }
      root["sources"] = sources
    }
    let json = try JSONSerialization.data(withJSONObject: root)
    guard let string = String(data: json, encoding: .utf8) else { throw NaviEsriTransport.failure() }
    return string
  }

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    precondition(Thread.isMainThread)
    guard !closed, let name = styleName, style.name == name,
          name == "navi-style-\(state.snapshot.generation)", state.ready(state.snapshot.generation) else { return }
    deadline?.cancel()
    let route = MLNShapeSource(identifier: "navi-route", shape: routeShape, options: nil)
    let position = MLNShapeSource(identifier: "navi-position", shape: nil, options: nil)
    let destination = MLNShapeSource(identifier: "navi-target", shape: nil, options: nil)
    [route, position, destination].forEach { style.addSource($0) }
    routeSource = route
    positionSource = position
    targetSource = destination
    let outline = MLNLineStyleLayer(identifier: "navi-route-outline", source: route)
    outline.lineColor = NSExpression(forConstantValue: UIColor(red: 0.98, green: 0.976, blue: 0.96, alpha: 1))
    outline.lineWidth = NSExpression(forConstantValue: 9)
    outline.lineJoin = NSExpression(forConstantValue: "round")
    outline.lineCap = NSExpression(forConstantValue: "round")
    style.addLayer(outline)
    let line = MLNLineStyleLayer(identifier: "navi-route-line", source: route)
    line.lineColor = NSExpression(forConstantValue: UIColor(red: 0.16, green: 0.17, blue: 0.16, alpha: 1))
    line.lineWidth = NSExpression(forConstantValue: 5)
    line.lineJoin = NSExpression(forConstantValue: "round")
    line.lineCap = NSExpression(forConstantValue: "round")
    style.addLayer(line)
    for (identifier, source, color) in [("navi-target-dot", destination, UIColor(red: 0.16, green: 0.17, blue: 0.16, alpha: 1)),
                                       ("navi-position-dot", position, UIColor(red: 0.32, green: 0.44, blue: 0.30, alpha: 1))] {
      let dot = MLNCircleStyleLayer(identifier: identifier, source: source)
      dot.circleColor = NSExpression(forConstantValue: color)
      dot.circleRadius = NSExpression(forConstantValue: 7)
      dot.circleStrokeColor = NSExpression(forConstantValue: UIColor(red: 0.98, green: 0.976, blue: 0.96, alpha: 1))
      dot.circleStrokeWidth = NSExpression(forConstantValue: 3)
      style.addLayer(dot)
    }
    renderPoints()
    let peers = MLNShapeSource(identifier: "navi-friends", shape: nil, options: nil)
    style.addSource(peers); friendsSource = peers
    let dots = MLNCircleStyleLayer(identifier: "navi-friends-dot", source: peers)
    dots.circleRadius = NSExpression(forConstantValue: 7)
    dots.circleColor = NSExpression(forConstantValue: UIColor(red: 0.32, green: 0.44, blue: 0.30, alpha: 1))
    dots.circleStrokeWidth = NSExpression(forConstantValue: 3)
    dots.circleStrokeColor = NSExpression(forConstantValue: UIColor(white: 0.98, alpha: 1))
    style.addLayer(dots)
    let labels = MLNSymbolStyleLayer(identifier: "navi-friends-label", source: peers)
    labels.iconImageName = NSExpression(forKeyPath: "caption")
    labels.iconAnchor = NSExpression(forConstantValue: "bottom")
    labels.iconOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -12)))
    labels.iconRotationAlignment = NSExpression(forConstantValue: "viewport")
    labels.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
    style.addLayer(labels)
    renderFriends()
    onState?(state.snapshot)
  }
  func mapView(_ mapView: MLNMapView, regionWillChangeAnimated animated: Bool) {
    if mapView.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true { following = false }
  }
  func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
    onViewportChanged?(mapView.centerCoordinate, mapView.zoomLevel)
  }

  func render(_ snapshot: NaviRouteSnapshot) {
    precondition(Thread.isMainThread)
    guard !closed else { return }
    let ready = snapshot.state == .preview || snapshot.state == .navigating
    if !ready {
      geometry.removeAll()
      geometryRevision = nil
      routeShape = nil
      routeSource?.shape = nil
    } else if snapshot.geometryIncluded {
      geometry = snapshot.geometry.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
      geometryRevision = NSNumber(value: snapshot.revision)
      if geometry.count > 1 {
        var coordinates = geometry
        let count = UInt(coordinates.count)
        routeShape = MLNPolyline(coordinates: &coordinates, count: count)
      } else { routeShape = nil }
      routeSource?.shape = routeShape
    }
  }
  func setTarget(_ coordinate: CLLocationCoordinate2D?) {
    precondition(Thread.isMainThread)
    target = coordinate
    renderPoints()
  }
  func setLocation(_ location: CLLocation?) {
    precondition(Thread.isMainThread)
    // The UI refresh timer may read the same GPS sample several times. Do not
    // restart a camera animation or rebuild the position source for that sample.
    if self.location == nil && location == nil { return }
    if let previous = self.location, let location, previous.isEqual(location) { return }
    self.location = location
    renderPoints()
    if following, let location {
      if view.zoomLevel < 2 { view.setCenter(location.coordinate, zoomLevel: 16, animated: true) }
      else { view.setCenter(location.coordinate, animated: true) }
    }
  }
  func setFollowing(_ enabled: Bool) {
    precondition(Thread.isMainThread)
    following = enabled
    if enabled, let location { view.setCenter(location.coordinate, zoomLevel: 16, animated: true) }
  }
  func fitRoute() {
    precondition(Thread.isMainThread)
    following = false
    guard geometry.count > 1 else { return }
    var coordinates = geometry
    let count = UInt(coordinates.count)
    view.setVisibleCoordinates(&coordinates, count: count,
      edgePadding: UIEdgeInsets(top: 160, left: 48, bottom: 280, right: 48), animated: true)
  }
  private func renderPoints() {
    func point(_ coordinate: CLLocationCoordinate2D?) -> MLNPointFeature? {
      guard let coordinate else { return nil }
      let point = MLNPointFeature()
      point.coordinate = coordinate
      return point
    }
    positionSource?.shape = point(location?.coordinate)
    targetSource?.shape = point(target)
  }
  func setFriends(_ values: [NaviFriendMarker]) {
    precondition(Thread.isMainThread)
    guard !closed else { return }
    var seen = Set<String>()
    let valid = values.filter {
      !$0.uid.isEmpty && CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        && seen.insert($0.uid).inserted
    }
    guard valid != friends else { return }
    friends = valid
    renderFriends()
  }
  @discardableResult func focusFriend(_ uid: String) -> Bool {
    precondition(Thread.isMainThread)
    guard !closed, let marker = friends.first(where: { $0.uid == uid }) else { return false }
    following = false
    view.setCenter(CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude), zoomLevel: 15, animated: true)
    return true
  }
  private func renderFriends() {
    guard let source = friendsSource, let style = view.style else { return }
    let current = Set(friends.map { $0.uid })
    for uid in Array(friendCaptions.keys) where !current.contains(uid) {
      style.removeImage(forName: "navi-peer-" + uid)
      friendCaptions.removeValue(forKey: uid)
    }
    let features = friends.map { marker -> MLNPointFeature in
      let imageName = "navi-peer-" + marker.uid
      let signature = marker.label + (marker.stale ? "/stale" : "/current")
      if friendCaptions[marker.uid] != signature {
        style.setImage(Self.caption(marker.label, stale: marker.stale), forName: imageName)
        friendCaptions[marker.uid] = signature
      }
      let feature = MLNPointFeature()
      feature.coordinate = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
      feature.attributes = ["uid": marker.uid, "label": marker.label, "stale": marker.stale, "caption": imageName]
      return feature
    }
    source.shape = MLNShapeCollectionFeature(shapes: features)
  }
  private static func caption(_ text: String, stale: Bool) -> UIImage {
    // Local UIKit text supports names on either basemap without extra glyph requests.
    let label = UILabel()
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.text = text; label.numberOfLines = 1; label.lineBreakMode = .byTruncatingTail
    label.textAlignment = .center
    label.textColor = UIColor(white: stale ? 0.40 : 0.16, alpha: 1)
    let size = CGSize(width: min(260, max(64, ceil(label.intrinsicContentSize.width) + 24)), height: 36)
    return UIGraphicsImageRenderer(size: size).image { _ in
      UIColor(red: 0.98, green: 0.976, blue: 0.96, alpha: 1).setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 18).fill()
      label.drawText(in: CGRect(x: 12, y: 0, width: size.width - 24, height: size.height))
    }
  }
  func close() {
    precondition(Thread.isMainThread)
    guard !closed else { return }
    closed = true
    state.detach()
    deadline?.cancel()
    view.delegate = nil
    transport.onFailure = nil
    transport.close()
    routeSource = nil
    targetSource = nil
    positionSource = nil
    friendsSource = nil; friends.removeAll(); friendCaptions.removeAll()
    geometry.removeAll()
    routeShape = nil
    onState = nil
    onViewportChanged = nil
  }
}
