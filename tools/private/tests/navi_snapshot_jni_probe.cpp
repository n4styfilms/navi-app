#include "app/organicmaps/sdk/routing/NaviRouteSnapshot.hpp"

extern "C" JNIEXPORT jobject JNICALL Java_SnapshotProbe_read(JNIEnv * env, jclass, jint scenario, jlong knownRevision)
{
  navi::RouteSnapshot snapshot;
  snapshot.revision = 42;
  snapshot.state = navi::RouteState::Navigating;
  snapshot.geometry = {{43.7295, 7.4208}, {43.7450, 7.4270}};
  snapshot.totalDistanceMeters = 120000.125;
  snapshot.remainingDistanceMeters = 123.75;
  snapshot.totalTimeSeconds = 4200.25;
  snapshot.remainingTimeSeconds = 81.5;
  snapshot.distanceToTurnMeters = 9.125;
  snapshot.speedLimitKmh = 50.0;
  snapshot.nextTurn = 7;
  snapshot.street = "Straße 🚗";
  snapshot.nextStreet = "東京";
  snapshot.turnNotifications = {"Rechts abbiegen", "Dann links"};
  snapshot.roadWarnings = {{navi::RoadWarningType::Toll, {43.7, 7.4}, 2.25},
                           {navi::RoadWarningType::Ferry, {44.7, 7.4}, 3.25},
                           {navi::RoadWarningType::Unpaved, {45.7, 7.4}, 4.25}};
  snapshot.trafficLights = {{43.74, 7.43}};
  snapshot.errorCode = 9;
  if (scenario == 1)
    snapshot.speedLimitKmh.reset();
  else if (scenario >= 2 && scenario <= 4)
  {
    snapshot = {};
    snapshot.revision = 43;
    if (scenario == 3) snapshot.state = navi::RouteState::Building;
    if (scenario == 4)
    {
      snapshot.state = navi::RouteState::Failed;
      snapshot.errorCode = navi::RouteSnapshot::kInvalidCoreData;
    }
  }
  else if (scenario == 5)
    snapshot.state = navi::RouteState::Preview;
  return ToJavaNaviRouteSnapshot(env, snapshot, knownRevision);
}
