import Foundation
// Only the unused route input is doubled in this isolated account/map fixture.
// Navigation and the real provider have separate full-main Core XCTest gates.
enum NaviRouteProbeState { case preview, navigating, none }
struct NaviRouteProbePoint { var latitude: Double; var longitude: Double }
struct NaviRouteSnapshot {
  var state = NaviRouteProbeState.none
  var geometryIncluded = false
  var geometry: [NaviRouteProbePoint] = []
  var revision: UInt64 = 0
}
