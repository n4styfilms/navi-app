import Foundation

private final class FixtureProtocol: URLProtocol {
  static let lock = NSLock()
  static var seen: [URLRequest] = []
  static var status = 200
  static var body = Data("{}".utf8)
  static var hold = false
  static let started = DispatchSemaphore(value: 0)
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.seen.append(request)
    let status = Self.status, body = Self.body, hold = Self.hold
    Self.lock.unlock()
    if hold { Self.started.signal(); return }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@main private struct Probe {
  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }
  static func main() {
    let key = "SYNTHETIC_SECRET_not_real"
    let configuration = NaviEsriConfiguration(key: key, language: "de")
    let state = NaviMapLoadState()
    let transport = NaviEsriTransport(configuration: configuration, state: state, testProtocolClasses: [FixtureProtocol.self])
    defer { transport.close() }
    func request(_ url: String, generation: UInt64) -> NaviEsriTransport.Response {
      let done = DispatchSemaphore(value: 0)
      var response: NaviEsriTransport.Response?
      var request = URLRequest(url: URL(string: url)!)
      request.setValue("Bearer " + key, forHTTPHeaderField: "X-Esri-Authorization")
      request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
      transport.perform(request, generation: generation) { result in response = result; done.signal() }
      check(done.wait(timeout: .now() + 5) == .success, "fixture request timed out")
      return response!
    }
    func lastRequest() -> URLRequest {
      FixtureProtocol.lock.lock(); defer { FixtureProtocol.lock.unlock() }
      return FixtureProtocol.seen.last!
    }
    var generation = state.begin(.street, configured: true)
    if case .failure = request("https://tiles.openfreemap.org/styles/liberty", generation: generation) { fatalError("public map failed") }
    check(lastRequest().value(forHTTPHeaderField: "X-Esri-Authorization") == nil, "public Esri credential leak")
    check(lastRequest().value(forHTTPHeaderField: "Authorization") == nil, "public bearer credential leak")
    check(lastRequest().value(forHTTPHeaderField: "User-Agent")?.contains("NaviPrivate/") == true, "missing app User-Agent")
    FixtureProtocol.lock.lock(); FixtureProtocol.status = 304; FixtureProtocol.body = Data(); FixtureProtocol.lock.unlock()
    switch request("https://tiles.openfreemap.org/styles/liberty", generation: generation) {
    case .failure: fatalError("valid cache validation paused the map")
    case .success(let result):
      check(result.0.isEmpty && result.1.statusCode == 304, "cache validation response changed")
    }
    check(state.snapshot.status == .loading, "cache validation changed map generation")
    FixtureProtocol.lock.lock(); FixtureProtocol.status = 200; FixtureProtocol.body = Data("{}".utf8); FixtureProtocol.lock.unlock()
    if case .failure = request("https://tiles.arcgis.com/tile", generation: generation) { fatalError("trusted Esri failed") }
    check(lastRequest().value(forHTTPHeaderField: "X-Esri-Authorization") == "Bearer " + key, "Esri header missing")
    let count = transport.requestCount
    if case .success = request("https://arcgis.com.attacker.example/tile", generation: generation) { fatalError("untrusted host accepted") }
    check(transport.requestCount == count, "untrusted host reached network")
    FixtureProtocol.lock.lock(); FixtureProtocol.hold = true; FixtureProtocol.lock.unlock()
    let cancelled = DispatchSemaphore(value: 0)
    var cancelledResult: NaviEsriTransport.Response?
    let cancelledTask = transport.perform(URLRequest(url: URL(string: "https://tiles.openfreemap.org/tile")!), generation: generation) {
      cancelledResult = $0; cancelled.signal()
    }
    check(FixtureProtocol.started.wait(timeout: .now() + 5) == .success, "cancelled fixture did not start")
    cancelledTask?.cancel()
    check(cancelled.wait(timeout: .now() + 5) == .success, "cancelled fixture did not complete")
    if case .success? = cancelledResult { fatalError("cancelled fixture unexpectedly completed") }
    check(state.snapshot.status == .loading, "ordinary tile cancellation paused map")
    FixtureProtocol.lock.lock(); FixtureProtocol.hold = false; FixtureProtocol.lock.unlock()
    for code in [301, 302, 307, 308, 401, 403, 429, 498, 499, 503] {
      generation = state.begin(.satellite, configured: true)
      FixtureProtocol.lock.lock(); FixtureProtocol.status = code; FixtureProtocol.body = Data(key.utf8); FixtureProtocol.lock.unlock()
      switch request("https://tiles.arcgis.com/tile?synthetic=" + key, generation: generation) {
      case .success: fatalError("HTTP failure accepted")
      case .failure(let error):
        check(!String(describing: error).contains(key), "unsafe error description")
        check((error as NSError).userInfo[NSUnderlyingErrorKey] == nil, "unsafe underlying network error")
      }
      check(state.snapshot.status == NaviMapLoadState.Status.failure(httpStatus: code), "wrong failure state")
      let failedCount = transport.requestCount
      _ = request("https://tiles.arcgis.com/tile", generation: generation)
      check(transport.requestCount == failedCount, "failed generation retried silently")
    }
    generation = state.begin(.satellite, configured: true)
    FixtureProtocol.lock.lock(); FixtureProtocol.status = 200
    FixtureProtocol.body = Data("{\"error\":{\"code\":498,\"message\":\"\(key)\"}}".utf8)
    FixtureProtocol.lock.unlock()
    _ = request("https://tiles.arcgis.com/tile", generation: generation)
    check(state.snapshot.status == .authError, "HTTP200 Esri error envelope accepted")
    let old = generation
    generation = state.begin(.street, configured: true)
    _ = request("https://tiles.arcgis.com/tile", generation: old)
    check(state.snapshot.status == .loading && state.snapshot.generation == generation, "stale request changed latest generation")
    state.detach()
    let detachedCount = transport.requestCount
    _ = request("https://tiles.openfreemap.org/styles/liberty", generation: generation)
    check(transport.requestCount == detachedCount, "detached request reached network")
    print("PASS actual Swift URLSession map transport, public auth stripping, trusted hosts and scoped failures")
  }
}
