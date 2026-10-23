package app.organicmaps.sdk.routing;

import androidx.annotation.Keep;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** Copied GUI-thread route values. Nullable metrics are unknown, never an invented zero route. */
@Keep
public final class NaviRouteSnapshot
{
  public enum State { NONE, BUILDING, PREVIEW, NAVIGATING, FAILED }
  public enum WarningType { TOLL, FERRY, UNPAVED }

  @Keep
  public static final class LatLon
  {
    public final double latitude;
    public final double longitude;
    private LatLon(double latitude, double longitude)
    {
      this.latitude = latitude;
      this.longitude = longitude;
    }
  }

  @Keep
  public static final class RoadWarning
  {
    public final WarningType type;
    public final LatLon position;
    public final double distanceMeters;
    private RoadWarning(int type, LatLon position, double distanceMeters)
    {
      this.type = WarningType.values()[type];
      this.position = position;
      this.distanceMeters = distanceMeters;
    }
  }

  public final long revision;
  public final State state;
  /** False only when a ready route's geometry already belongs to the caller's revision. */
  public final boolean geometryIncluded;
  public final List<LatLon> geometry;
  public final Double totalDistanceMeters;
  public final Double remainingDistanceMeters;
  public final Double totalTimeSeconds;
  public final Double remainingTimeSeconds;
  public final Double distanceToTurnMeters;
  public final Double speedLimitKmh;
  public final int nextTurn;
  public final String street;
  public final String nextStreet;
  public final List<String> turnNotifications;
  public final List<RoadWarning> roadWarnings;
  public final List<LatLon> trafficLights;
  public final int errorCode;

  private static <T> List<T> copy(T[] values)
  {
    return Collections.unmodifiableList(Arrays.asList(values.clone()));
  }

  // Invoked by the native value mapper; no native references survive this constructor.
  private NaviRouteSnapshot(long revision, int state, boolean geometryIncluded, LatLon[] geometry,
                            Double totalDistanceMeters, Double remainingDistanceMeters,
                            Double totalTimeSeconds, Double remainingTimeSeconds,
                            Double distanceToTurnMeters, Double speedLimitKmh, int nextTurn,
                            String street, String nextStreet, String[] turnNotifications,
                            RoadWarning[] roadWarnings, LatLon[] trafficLights, int errorCode)
  {
    this.revision = revision;
    this.state = State.values()[state];
    this.geometryIncluded = geometryIncluded;
    this.geometry = copy(geometry);
    this.totalDistanceMeters = totalDistanceMeters;
    this.remainingDistanceMeters = remainingDistanceMeters;
    this.totalTimeSeconds = totalTimeSeconds;
    this.remainingTimeSeconds = remainingTimeSeconds;
    this.distanceToTurnMeters = distanceToTurnMeters;
    this.speedLimitKmh = speedLimitKmh;
    this.nextTurn = nextTurn;
    this.street = street;
    this.nextStreet = nextStreet;
    this.turnNotifications = copy(turnNotifications);
    this.roadWarnings = copy(roadWarnings);
    this.trafficLights = copy(trafficLights);
    this.errorCode = errorCode;
  }

  public boolean isReady()
  {
    return state == State.PREVIEW || state == State.NAVIGATING;
  }
}
