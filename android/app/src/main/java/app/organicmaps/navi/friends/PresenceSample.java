package app.organicmaps.navi.friends;

/** Immutable copy of one sample from the existing location provider. */
public final class PresenceSample {
  public final long sequence;
  public final long measuredAtMs;
  public final double latitude;
  public final double longitude;
  public final Double accuracyMeters;
  private final Double speed;
  private final Double bearing;

  public PresenceSample(long sequence, long measuredAtMs, double latitude, double longitude,
                        Double accuracyMeters, Double metersPerSecond, Double bearingDegrees) {
    this.sequence = sequence;
    this.measuredAtMs = measuredAtMs;
    this.latitude = latitude;
    this.longitude = longitude;
    this.accuracyMeters = accuracyMeters;
    speed = finite(metersPerSecond) && metersPerSecond >= 0 ? metersPerSecond : null;
    bearing = finite(bearingDegrees) ? ((bearingDegrees % 360) + 360) % 360 : null;
  }

  private static boolean finite(Double value) {
    return value != null && !Double.isNaN(value) && !Double.isInfinite(value);
  }

  public boolean isValid() {
    return sequence > 0 && sequence <= 9007199254740991L && measuredAtMs > 0
        && finite(latitude) && latitude >= -90 && latitude <= 90
        && finite(longitude) && longitude >= -180 && longitude <= 180
        && finite(accuracyMeters) && accuracyMeters >= 0;
  }

  public boolean isFreshAt(long nowMs) {
    return isValid() && nowMs >= measuredAtMs && nowMs - measuredAtMs <= 15000;
  }

  public Double speedMetersPerSecond() { return speed; }
  public Double bearingDegrees() { return bearing; }
}
