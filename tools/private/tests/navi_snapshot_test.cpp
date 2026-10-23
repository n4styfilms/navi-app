// Dependency-free behavior checks of the production snapshot boundary.
#include "map/navi_route_snapshot.hpp"

#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace
{
void Require(bool value, char const * message)
{
  if (!value)
    throw std::runtime_error(message);
}

navi::RouteSnapshot Ready()
{
  navi::RouteSnapshot snapshot;
  snapshot.state = navi::RouteState::Preview;
  snapshot.geometry = {{43.7295, 7.4208}, {43.7450, 7.4270}};
  snapshot.totalDistanceMeters = 120000.125;
  snapshot.remainingDistanceMeters = 119999.875;
  snapshot.totalTimeSeconds = 7200.5;
  snapshot.remainingTimeSeconds = 7199.25;
  return snapshot;
}

void EmptyIsNotZeroDistance()
{
  navi::RouteSnapshotStore store;
  auto const snapshot = store.Read();
  Require(snapshot.state == navi::RouteState::None, "startup state");
  Require(!snapshot.totalDistanceMeters, "missing route must not become zero meters");
  Require(!snapshot.speedLimitKmh, "unknown limit must not become a guessed limit");
}

void CopiesKeepExactValues()
{
  navi::RouteSnapshotStore store;
  auto const revision = store.BeginBuild();
  auto payload = Ready();
  Require(store.Publish(revision, payload), "current route must publish");
  payload.geometry[0].latitude = 0;
  auto read = store.Read();
  Require(read.geometry[0].latitude == 43.7295, "payload alias escaped boundary");
  Require(*read.totalDistanceMeters == 120000.125, "route meters were rounded");
  Require(*read.remainingTimeSeconds == 7199.25, "route duration was rounded");
  read.geometry.clear();
  Require(store.Read().geometry.size() == 2, "consumer mutated stored route");
}

void CancelRejectsLateResult()
{
  navi::RouteSnapshotStore store;
  auto const revision = store.BeginBuild();
  store.Clear();
  Require(!store.Publish(revision, Ready()), "cancelled build revived route");
  auto const snapshot = store.Read();
  Require(snapshot.revision > revision, "cancel did not invalidate revision");
  Require(snapshot.geometry.empty() && !snapshot.totalDistanceMeters, "cancel retained route or cost input");
}

void NewBuildRejectsOldResult()
{
  navi::RouteSnapshotStore store;
  auto const oldRevision = store.BeginBuild();
  auto const newRevision = store.BeginBuild();
  Require(newRevision > oldRevision, "build revision did not advance");
  Require(!store.Publish(oldRevision, Ready()), "old build replaced new request");
  Require(store.Publish(newRevision, Ready()), "new build cannot publish");
  Require(store.Read().revision == newRevision, "payload did not inherit request revision");
  Require(!store.Publish(newRevision, Ready()), "completed build accepted duplicate callback");
}

void InvalidPayloadDoesNotBecomeReady()
{
  navi::RouteSnapshotStore store;
  auto revision = store.BeginBuild();
  auto payload = Ready();
  payload.geometry[0].latitude = 120;
  Require(!store.Publish(revision, payload), "out-of-range latitude accepted");
  payload = Ready();
  payload.totalDistanceMeters = std::numeric_limits<double>::infinity();
  Require(!store.Publish(revision, payload), "infinite distance accepted");
  payload = Ready();
  payload.remainingDistanceMeters = -1;
  Require(!store.Publish(revision, payload), "negative distance accepted");
  payload = Ready();
  payload.totalTimeSeconds.reset();
  Require(!store.Publish(revision, payload), "missing route duration accepted");
  payload = Ready();
  payload.speedLimitKmh = std::numeric_limits<double>::quiet_NaN();
  Require(!store.Publish(revision, payload), "invalid speed limit accepted");
  payload = Ready();
  payload.state = navi::RouteState::None;
  Require(!store.Publish(revision, payload), "non-ready payload accepted");
  Require(store.Read().state == navi::RouteState::Building, "invalid payload replaced pending build");
  Require(store.Publish(revision, Ready()), "invalid callback poisoned current request");
}

void ZeroDistanceRemainsValid()
{
  navi::RouteSnapshotStore store;
  auto const revision = store.BeginBuild();
  auto payload = Ready();
  payload.totalDistanceMeters = 0;
  payload.remainingDistanceMeters = 0;
  Require(store.Publish(revision, payload), "zero distance confused with missing route");
  Require(store.Read().totalDistanceMeters == 0, "zero value was discarded");
}

void FailureInvalidatesReadyData()
{
  navi::RouteSnapshotStore store;
  auto const oldRevision = store.BeginBuild();
  Require(store.Publish(oldRevision, Ready()), "route must publish");
  auto const revision = store.BeginBuild();
  Require(!store.Fail(oldRevision, 9), "old error overwrote current build");
  Require(store.Fail(revision, 9), "current error not applied");
  auto const snapshot = store.Read();
  Require(snapshot.state == navi::RouteState::Failed && snapshot.errorCode == 9, "failure state lost");
  Require(snapshot.geometry.empty() && !snapshot.totalDistanceMeters, "failure retained cost input");
  Require(!store.Publish(revision, Ready()), "late success revived failed build");
}
}

int main()
{
  using Test = void (*)();
  Test const tests[] = {EmptyIsNotZeroDistance, CopiesKeepExactValues, CancelRejectsLateResult,
                        NewBuildRejectsOldResult, InvalidPayloadDoesNotBecomeReady,
                        ZeroDistanceRemainsValid, FailureInvalidatesReadyData};
  try
  {
    for (auto test : tests)
      test();
    std::cout << "PASS 7 snapshot behavior cases\n";
    return 0;
  }
  catch (std::exception const & error)
  {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
