/// Immutable copy of one sample from the existing location provider.
struct PresenceSample: Sendable {
  let sequence: Int64
  let measuredAtMs: Int64
  let latitude: Double
  let longitude: Double
  let accuracyMeters: Double?
  let speedMetersPerSecond: Double?
  let bearingDegrees: Double?

  init(sequence: Int64, measuredAtMs: Int64, latitude: Double, longitude: Double,
       accuracyMeters: Double?, metersPerSecond: Double?, bearingDegrees: Double?) {
    self.sequence = sequence
    self.measuredAtMs = measuredAtMs
    self.latitude = latitude
    self.longitude = longitude
    self.accuracyMeters = accuracyMeters
    if let speed = metersPerSecond, speed.isFinite, speed >= 0 {
      self.speedMetersPerSecond = speed
    } else {
      self.speedMetersPerSecond = nil
    }
    if let bearing = bearingDegrees, bearing.isFinite {
      self.bearingDegrees = (bearing.truncatingRemainder(dividingBy: 360) + 360)
        .truncatingRemainder(dividingBy: 360)
    } else {
      self.bearingDegrees = nil
    }
  }

  var isValid: Bool {
    guard sequence > 0, sequence <= 9_007_199_254_740_991, measuredAtMs > 0,
          latitude.isFinite, (-90...90).contains(latitude),
          longitude.isFinite, (-180...180).contains(longitude),
          let accuracy = accuracyMeters, accuracy.isFinite, accuracy >= 0 else { return false }
    return true
  }

  func isFresh(at nowMs: Int64) -> Bool {
    isValid && nowMs >= measuredAtMs && nowMs - measuredAtMs <= 15_000
  }
}
