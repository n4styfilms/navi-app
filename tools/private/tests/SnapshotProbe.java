import app.organicmaps.sdk.routing.NaviRouteSnapshot;

/** Exercises the production JNI value mapper; this is not an Android lifecycle test. */
public final class SnapshotProbe
{
  private static native NaviRouteSnapshot read(int scenario, long knownGeometryRevision);

  private static void check(boolean condition, String message)
  {
    if (!condition) throw new AssertionError(message);
  }

  public static void main(String[] args)
  {
    System.load(args[0]);
    NaviRouteSnapshot full = read(0, -1);
    check(full.revision == 42 && full.state == NaviRouteSnapshot.State.NAVIGATING, "revision/state");
    check(full.geometryIncluded && full.geometry.size() == 2, "geometry");
    check(full.geometry.get(0).latitude == 43.7295 && full.geometry.get(0).longitude == 7.4208,
          "lat/lon reversed");
    check(full.totalDistanceMeters == 120000.125 && full.remainingDistanceMeters == 123.75, "meters");
    check(full.totalTimeSeconds == 4200.25 && full.remainingTimeSeconds == 81.5, "seconds");
    check(full.distanceToTurnMeters == 9.125 && full.speedLimitKmh == 50.0, "turn/limit units");
    check(full.nextTurn == 7 && full.street.equals("Straße 🚗") && full.nextStreet.equals("東京"), "text/turn");
    check(full.turnNotifications.size() == 2 && full.turnNotifications.get(0).equals("Rechts abbiegen"), "TTS");
    check(full.roadWarnings.size() == 3, "warnings");
    for (int i = 0; i < 3; i++)
    {
      var warning = full.roadWarnings.get(i);
      check(warning.type.ordinal() == i && warning.position.latitude == 43.7 + i
            && warning.position.longitude == 7.4 && warning.distanceMeters == 2.25 + i, "warning mapping");
    }
    check(full.trafficLights.size() == 1 && full.trafficLights.get(0).longitude == 7.43, "traffic lights");
    check(full.errorCode == 9, "rebuild error");
    try { full.geometry.clear(); throw new AssertionError("mutable geometry"); }
    catch (UnsupportedOperationException expected) {}
    try { full.turnNotifications.add("changed"); throw new AssertionError("mutable TTS"); }
    catch (UnsupportedOperationException expected) {}
    try { full.roadWarnings.clear(); throw new AssertionError("mutable warnings"); }
    catch (UnsupportedOperationException expected) {}

    NaviRouteSnapshot progress = read(0, 42);
    check(!progress.geometryIncluded && progress.geometry.isEmpty(), "same revision retransmitted geometry");
    check(progress.remainingDistanceMeters == 123.75, "delta lost progress");
    NaviRouteSnapshot unknownLimit = read(1, -1);
    check(unknownLimit.speedLimitKmh == null, "missing limit fabricated");
    NaviRouteSnapshot cancelled = read(2, 42);
    check(cancelled.revision == 43 && cancelled.state == NaviRouteSnapshot.State.NONE, "cancel revision/state");
    check(cancelled.geometryIncluded && cancelled.geometry.isEmpty() && cancelled.totalDistanceMeters == null
          && cancelled.remainingDistanceMeters == null && cancelled.totalTimeSeconds == null
          && cancelled.remainingTimeSeconds == null && cancelled.distanceToTurnMeters == null
          && cancelled.speedLimitKmh == null, "cancel retained cost/overlay inputs");
    check(full.geometry.size() == 2 && full.totalDistanceMeters == 120000.125, "old value mutated");
    NaviRouteSnapshot building = read(3, 42);
    check(building.state == NaviRouteSnapshot.State.BUILDING && building.geometryIncluded
          && building.geometry.isEmpty() && building.totalDistanceMeters == null, "building metrics");
    NaviRouteSnapshot failed = read(4, -1);
    check(failed.state == NaviRouteSnapshot.State.FAILED && failed.errorCode == -1
          && failed.totalDistanceMeters == null, "failed state");
    NaviRouteSnapshot preview = read(5, -1);
    check(preview.state == NaviRouteSnapshot.State.PREVIEW, "preview state");
    System.out.println("PASS production JNI snapshot mapping, missing metrics, delta geometry and immutable copies");
  }
}
