import Foundation

enum NaviBasemapMode: String { case street, satellite }

struct NaviEsriConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
  private let key: String
  private let language: String
  let isConfigured: Bool
  var description: String { "NaviEsriConfiguration(configured: \(isConfigured))" }
  var debugDescription: String { description }

  init(key: String, language: String) {
    let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
    self.key = cleaned
    let validLanguage = language.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$",
                                       options: .regularExpression) != nil
    self.language = validLanguage ? language : "en"
    isConfigured = !cleaned.isEmpty && cleaned.utf8.allSatisfy { (33...126).contains($0) } && validLanguage
  }

  func styleURL(_ mode: NaviBasemapMode) -> URL {
    if mode == .street { return URL(string: "https://tiles.openfreemap.org/styles/liberty")! }
    var url = URLComponents(string: "https://basemapstyles-api.arcgis.com/arcgis/rest/services/styles/v2/styles/arcgis/imagery")!
    url.queryItems = [URLQueryItem(name: "language", value: language), URLQueryItem(name: "echoToken", value: "false")]
    return url.url!
  }
  func canLoad(_ mode: NaviBasemapMode) -> Bool { mode == .street || isConfigured }
  static func isPublicResource(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
      (url.port == nil || url.port == 443) && url.host?.lowercased() == "tiles.openfreemap.org"
  }

  func authorization(for url: URL) -> String? {
    guard isConfigured, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443, let host = url.host?.lowercased(),
          host == "arcgis.com" || host.hasSuffix(".arcgis.com") ||
          host == "arcgisonline.com" || host.hasSuffix(".arcgisonline.com") else { return nil }
    return "Bearer " + key
  }
}

/// Synchronized policy shared by GUI callbacks and background URL loading; owns no route or location.
final class NaviMapLoadState {
  enum Status: CaseIterable {
    case configurationRequired, loading, ready, authError, quotaReached, networkError, styleError, detached
    var message: String {
      switch self {
      case .configurationRequired: return "Enter your map access key."
      case .loading: return "Loading map…"
      case .ready: return ""
      case .authError: return "Check your map access key."
      case .quotaReached: return "Map request allowance reached. Retry explicitly later."
      case .networkError: return "Map connection failed. Tap to retry."
      case .styleError: return "Map could not be loaded. Tap to retry."
      case .detached: return ""
      }
    }
    static func failure(httpStatus: Int) -> Self {
      if [401, 403, 498, 499].contains(httpStatus) { return .authError }
      if httpStatus == 429 { return .quotaReached }
      return httpStatus >= 500 ? .networkError : .styleError
    }
  }
  struct Snapshot {
    let generation: UInt64
    let mode: NaviBasemapMode
    let status: Status
  }
  private let lock = NSLock()
  private var current = Snapshot(generation: 0, mode: .street, status: .detached)

  var snapshot: Snapshot { synchronized { current } }
  private func synchronized<T>(_ block: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return block()
  }
  @discardableResult func begin(_ mode: NaviBasemapMode, configured: Bool) -> UInt64 {
    synchronized {
      current = Snapshot(generation: current.generation + 1, mode: mode,
                         status: configured ? .loading : .configurationRequired)
      return current.generation
    }
  }
  @discardableResult func ready(_ generation: UInt64) -> Bool {
    synchronized {
      guard current.generation == generation, current.status == .loading else { return false }
      current = Snapshot(generation: generation, mode: current.mode, status: .ready)
      return true
    }
  }
  @discardableResult func fail(_ generation: UInt64, _ status: Status) -> Bool {
    precondition([.authError, .quotaReached, .networkError, .styleError].contains(status))
    return synchronized {
      guard current.generation == generation, current.status == .loading || current.status == .ready else { return false }
      current = Snapshot(generation: generation, mode: current.mode, status: status)
      return true
    }
  }
  func canRequest(_ generation: UInt64) -> Bool {
    synchronized { current.generation == generation && (current.status == .loading || current.status == .ready) }
  }
  func detach() {
    synchronized { current = Snapshot(generation: current.generation + 1, mode: current.mode, status: .detached) }
  }
}
