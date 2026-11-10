import UIKit

@main final class FriendsProbeApp: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Preserve completed proof markers even if a later SDK exception aborts the process.
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    print("NAVI_APPLE_NATIVE_STARTED")
    let window = UIWindow(frame: UIScreen.main.bounds)
    let view = UIViewController()
    view.view.backgroundColor = .systemBackground
    window.rootViewController = view
    self.window = window
    window.makeKeyAndVisible()
    Task { @MainActor in
      do {
        let prefix = "--navi-proof-nonce="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
              let source = Bundle.main.object(forInfoDictionaryKey: "NaviSourceCommit") as? String else {
          throw ProbeError.failed("Missing proof launch identity")
        }
        let nonce = String(argument.dropFirst(prefix.count))
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
        let result = documents.appendingPathComponent("native-proof-result.json")
        if FileManager.default.fileExists(atPath: result.path) {
          try FileManager.default.removeItem(at: result)
        }
        func writeResult(status: String, proofs: [String], error: String? = nil) throws {
          var record: [String: Any] = ["nonce": nonce, "source": source, "status": status,
                                      "proofs": proofs]
          record["error"] = error
          try JSONSerialization.data(withJSONObject: record).write(to: result, options: .atomic)
        }
        do {
          try await FriendsNativeProbe.run()
        } catch {
          try writeResult(status: "failed", proofs: FriendsNativeProbe.proofs, error: String(describing: error))
          throw error
        }
        try writeResult(status: "passed", proofs: FriendsNativeProbe.proofs)
        exit(0)
      } catch {
        print("NAVI_APPLE_NATIVE_ERROR \(error)")
        exit(1)
      }
    }
    return true
  }
}
