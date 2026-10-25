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
        try await FriendsNativeProbe.run()
        exit(0)
      } catch {
        print("NAVI_APPLE_NATIVE_ERROR \(error)")
        exit(1)
      }
    }
    return true
  }
}
