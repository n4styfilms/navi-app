import Foundation

/// Same projection for the main map and the native account-to-renderer contract.
@MainActor enum FriendsMapProjection {
  static func markers(from peers: [FriendsRepository.Peer], at now: Int64) -> [NaviFriendMarker] {
    peers.compactMap { peer in
      guard now > 0, peer.positionAllowed, peer.sharingEnabled, let point = peer.position, point.isValid else { return nil }
      let name = peer.displayName.isEmpty ? NaviPalette.text("Freund", "Friend") : peer.displayName
      let label: String
      if let speed = peer.speedMetersPerSecond(at: now) {
        label = name + " · " + String(format: "%.0f km/h", speed * 3.6)
      } else if point.isFresh(at: now) { label = name }
      else if now >= point.measuredAtMs {
        let seconds = (now - point.measuredAtMs) / 1000
        let age = seconds < 60 ? "\(seconds) s" : seconds < 3600 ? "\(seconds / 60) min" : "\(seconds / 3600) h"
        label = name + " · " + NaviPalette.text("vor \(age)", "\(age) ago")
      } else { label = name + " · " + NaviPalette.text("Zeit unklar", "Time unknown") }
      return NaviFriendMarker(uid: peer.uid, latitude: point.latitude, longitude: point.longitude,
        label: label, stale: !point.isFresh(at: now))
    }
  }
}
