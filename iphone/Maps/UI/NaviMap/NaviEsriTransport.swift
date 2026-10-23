import Foundation

/// The SDK uses this protocol only in its own session configuration. Other app traffic is untouched.
final class NaviEsriURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static weak var owner: NaviEsriTransport?
  static func install(_ transport: NaviEsriTransport) {
    lock.lock(); defer { lock.unlock() }
    owner = transport
  }
  private static var active: NaviEsriTransport? {
    lock.lock(); defer { lock.unlock() }
    return owner
  }
  private let loadingLock = NSRecursiveLock()
  private var stopped = false
  private var loadingTask: URLSessionDataTask?

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.scheme == "https" || request.url?.scheme == "http"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let transport = Self.active else {
      client?.urlProtocol(self, didFailWithError: NaviEsriTransport.failure())
      return
    }
    let generation = transport.state.snapshot.generation
    let started = transport.perform(request, generation: generation) { [weak self] result in
      guard let self else { return }
      self.loadingLock.lock()
      defer { self.loadingLock.unlock() }
      guard !self.stopped else { return }
      switch result {
      case let .success((data, response)):
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !self.stopped else { return }
        self.client?.urlProtocol(self, didLoad: data)
        guard !self.stopped else { return }
        self.client?.urlProtocolDidFinishLoading(self)
      case let .failure(error): self.client?.urlProtocol(self, didFailWithError: error)
      }
    }
    loadingLock.lock()
    loadingTask = started
    let cancel = stopped
    loadingLock.unlock()
    if cancel { started?.cancel() }
  }
  override func stopLoading() {
    loadingLock.lock()
    stopped = true
    let activeTask = loadingTask
    loadingTask = nil
    loadingLock.unlock()
    activeTask?.cancel()
  }
}

/// No URL, header, response body or third-party error is forwarded into a user-facing error.
final class NaviEsriTransport: NSObject, URLSessionTaskDelegate {
  typealias Response = Result<(Data, HTTPURLResponse), Error>
  let state: NaviMapLoadState
  var onFailure: ((UInt64) -> Void)?
  private let lock = NSLock()
  private var configuration: NaviEsriConfiguration
  private var count: UInt64 = 0
  private var tasks: [UUID: URLSessionDataTask] = [:]
  private let testProtocolClasses: [AnyClass]
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = testProtocolClasses
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 30
    config.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  init(configuration: NaviEsriConfiguration, state: NaviMapLoadState, testProtocolClasses: [AnyClass] = []) {
    self.configuration = configuration
    self.state = state
    self.testProtocolClasses = testProtocolClasses
    super.init()
    // Materialize the session on its GUI owner, before background protocol callbacks.
    _ = session
  }
  var requestCount: UInt64 {
    lock.lock(); defer { lock.unlock() }
    return count
  }
  func configure(_ configuration: NaviEsriConfiguration) {
    lock.lock()
    self.configuration = configuration
    lock.unlock()
  }
  static func failure() -> NSError {
    NSError(domain: "NaviMap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Map request failed."])
  }
  func fail(_ generation: UInt64, _ status: NaviMapLoadState.Status) {
    if state.fail(generation, status) { onFailure?(generation) }
  }
  @discardableResult func perform(_ original: URLRequest, generation: UInt64,
                                  completion: @escaping (Response) -> Void) -> URLSessionDataTask? {
    lock.lock()
    let config = configuration
    lock.unlock()
    guard state.canRequest(generation), let url = original.url else {
      completion(.failure(Self.failure()))
      return nil
    }
    let publicResource = NaviEsriConfiguration.isPublicResource(url)
    let auth = config.authorization(for: url)
    guard publicResource || auth != nil else { completion(.failure(Self.failure())); return nil }
    var request = original
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(publicResource ? nil : auth, forHTTPHeaderField: "X-Esri-Authorization")
    request.setValue("NaviPrivate/0.2 (MapLibre Native)", forHTTPHeaderField: "User-Agent")
    request.httpShouldHandleCookies = false
    request.timeoutInterval = 30
    let identity = UUID()
    let task = session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { completion(.failure(Self.failure())); return }
      self.lock.lock()
      self.tasks.removeValue(forKey: identity)
      self.lock.unlock()
      guard self.state.canRequest(generation) else { completion(.failure(Self.failure())); return }
      guard error == nil, let response = response as? HTTPURLResponse, let data else {
        // Cancelling an obsolete tile while panning is part of normal SDK use.
        if (error as? URLError)?.code != .cancelled { self.fail(generation, .networkError) }
        completion(.failure(Self.failure()))
        return
      }
      var status = response.statusCode
      if status == 200, response.mimeType?.contains("json") == true,
         let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let envelope = root["error"] as? [String: Any] { status = envelope["code"] as? Int ?? 400 }
      // MapLibre owns its resource cache and consumes HTTP 304 for revalidation.
      guard (200..<300).contains(status) || status == 304 else {
        self.fail(generation, .failure(httpStatus: status))
        completion(.failure(Self.failure()))
        return
      }
      completion(.success((data, response)))
    }
    lock.lock()
    count += 1
    tasks[identity] = task
    lock.unlock()
    task.resume()
    return task
  }
  func cancelAll() {
    lock.lock()
    let previous = Array(tasks.values)
    tasks.removeAll()
    lock.unlock()
    previous.forEach { $0.cancel() }
  }
  func close() { session.invalidateAndCancel() }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
