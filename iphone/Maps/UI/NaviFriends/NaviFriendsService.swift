import UIKit
import CoreLocation

/// Application lifetime, not map/sheet lifetime. No additional CLLocationManager.
@MainActor final class NaviFriendsService: NSObject, MWMLocationObserver {
  static let shared = NaviFriendsService()
  let runtime: FriendsRuntime?
  private var bridge: FriendsLocationBridge?
  private var attached = false
  private var mapVisible = false

  private override init() {
    runtime = try? FriendsRuntime(preferences: .standard)
    super.init()
    guard let runtime else { return }
    bridge = FriendsLocationBridge(runtime: runtime) { [weak self] demand in self?.applyDemand(demand) }
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(refreshVisibility), name: name, object: nil)
    }
  }
  private func applyDemand(_ demand: Bool) {
    LocationManager.setFriendsSharingActive(demand)
    if demand && !attached {
      attached = true; LocationManager.add(observer: self); LocationManager.start()
    } else if !demand && attached {
      attached = false; LocationManager.remove(observer: self)
    }
  }
  func setMapVisible(_ visible: Bool) { mapVisible = visible; refreshVisibility() }
  @objc private func refreshVisibility() {
    runtime?.setMapVisible(mapVisible && UIApplication.shared.applicationState == .active)
  }
  func onRawLocationUpdate(_ location: CLLocation) { bridge?.onRawLocationUpdate(location) }
}
