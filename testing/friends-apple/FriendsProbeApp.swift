import UIKit

@main final class FriendsProbeApp: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
