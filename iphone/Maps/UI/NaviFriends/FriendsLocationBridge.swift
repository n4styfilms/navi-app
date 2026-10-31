import Foundation
import CoreLocation

/// Account-owned connection to the existing provider, independent of any visible sheet.
@MainActor final class FriendsLocationBridge: NSObject {
  private let runtime: FriendsRuntime
  private let setDemand: (Bool) -> Void
  private var observation: FriendsRuntime.Observation?
  private var lastDemand: Bool?
  private var closed = false

  init(runtime: FriendsRuntime, setDemand: @escaping (Bool) -> Void) {
    self.runtime = runtime; self.setDemand = setDemand
    super.init()
    observation = runtime.observe { [weak self] _ in self?.refreshDemand() }
  }
  private func refreshDemand() {
    guard !closed else { return }
    let demand = runtime.locationDemand
    if lastDemand != demand { lastDemand = demand; setDemand(demand) }
  }
  static func copyFix(_ location: CLLocation) -> FriendsRuntime.Fix? {
    let time = location.timestamp.timeIntervalSince1970 * 1000
    guard time.isFinite, time > 0, time <= 9_007_199_254_740_991,
          CLLocationCoordinate2DIsValid(location.coordinate),
          location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 else { return nil }
    return .init(measuredAtDeviceMs: Int64(time.rounded()), latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude, accuracyMeters: location.horizontalAccuracy,
      metersPerSecond: location.speed.isFinite && location.speed >= 0 ? location.speed : nil,
      bearingDegrees: location.course.isFinite && location.course >= 0 ? location.course : nil)
  }
  @objc func onRawLocationUpdate(_ location: CLLocation) {
    guard !closed, let fix = Self.copyFix(location) else { return }
    Task { @MainActor [weak self] in
      guard let self, !self.closed else { return }
      // The model handles publication failures and revokes demand synchronously.
      _ = try? await self.runtime.acceptLocation(fix)
    }
  }
  func close() {
    guard !closed else { return }
    closed = true; observation?.close(); observation = nil
    if lastDemand == true { lastDemand = false; setDemand(false) }
  }
}
