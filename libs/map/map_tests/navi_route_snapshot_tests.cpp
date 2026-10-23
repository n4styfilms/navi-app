#include "map/navi_route_capture.hpp"

#include "testing/testing.hpp"
#include "routing/following_info.hpp"
#include "routing/route.hpp"
#include "routing/road_warnings.hpp"
#include "geometry/mercator.hpp"

#include <cmath>
#include <limits>

namespace
{
routing::Route ShortRoute(double latitude = 0, double longitude = 0)
{
  auto const start = mercator::FromLatLon(latitude, longitude);
  auto const end = mercator::FromLatLon(latitude, longitude + 0.000001);
  std::vector<m2::PointD> points{start, end};
  routing::Route route("vehicle", points.begin(), points.end(), 42);
  routing::RouteSegment segment(routing::Segment(0, 0, 0, true),
                               routing::turns::TurnItem(1, routing::turns::CarDirection::ReachedYourDestination),
                               geometry::PointWithAltitude(end), routing::RouteSegment::RoadNameInfo("Test road"));
  segment.SetDistancesAndTime(0.111, 0.000001, 12.5);
  route.SetRouteSegments({segment});
  return route;
}
}

UNIT_TEST(NaviSnapshot_CapturesRealUnroundedRouteMetrics)
{
  auto const route = ShortRoute();
  routing::FollowingInfo info;
  info.m_currentStreetName = "Test road";
  info.m_nextStreetName = "Next road";
  auto const snapshot = navi::CaptureRoute(7, navi::RouteState::Preview, route, info);
  TEST_EQUAL(snapshot.revision, 7, ());
  TEST_EQUAL(snapshot.geometry.size(), 2, ());
  TEST(snapshot.totalDistanceMeters, ());
  TEST_GREATER(*snapshot.totalDistanceMeters, 0.1, ());
  TEST_LESS(*snapshot.totalDistanceMeters, 0.12, ());
  TEST_EQUAL(*snapshot.totalTimeSeconds, 12.5, ());
  TEST_EQUAL(snapshot.street, "Test road", ());
  TEST_EQUAL(snapshot.nextStreet, "Next road", ());
  TEST(!snapshot.speedLimitKmh, ());
}

UNIT_TEST(NaviSnapshot_CoordinateOrderAndSpeedUnits)
{
  auto const route = ShortRoute(52.5, 13.4);
  routing::FollowingInfo info;
  info.m_speedLimitMps = 25;
  info.m_turn = routing::turns::CarDirection::TurnLeft;
  auto snapshot = navi::CaptureRoute(8, navi::RouteState::Navigating, route, info);
  TEST_LESS(std::abs(snapshot.geometry.front().latitude - 52.5), 1e-7, ());
  TEST_LESS(std::abs(snapshot.geometry.front().longitude - 13.4), 1e-7, ());
  TEST_EQUAL(*snapshot.speedLimitKmh, 90, ());
  TEST_EQUAL(snapshot.nextTurn, static_cast<int>(routing::turns::CarDirection::TurnLeft), ());
}

UNIT_TEST(NaviSnapshot_InvalidRouteHasNoCostInput)
{
  routing::Route route("vehicle", 42);
  routing::FollowingInfo info;
  auto const snapshot = navi::CaptureRoute(9, navi::RouteState::Preview, route, info);
  TEST(snapshot.state == navi::RouteState::None, ());
  TEST(snapshot.geometry.empty(), ());
  TEST(!snapshot.totalDistanceMeters, ());
  TEST(!snapshot.remainingDistanceMeters, ());
}

UNIT_TEST(NaviSnapshot_WarningsUseMetersAndStopAtBoundary)
{
  using Option = routing::RoutingOptions::Option;
  auto route = ShortRoute();
  auto segment = route.GetRouteSegments().front();
  std::vector<routing::RouteSegment> segments;
  double distance = 400; // A later subroute starts at 400 meters, not Mercator units.
  for (auto const type : {Option::Toll, Option::Toll, Option::Usual, Option::Ferry, Option::Dirty})
  {
    routing::RoutingOptions options;
    options.Add(type);
    segment.SetRoadTypes(options);
    distance += 25;
    segment.SetDistancesAndTime(distance, 0.000001, 12.5);
    segments.push_back(segment);
  }
  auto spans = routing::CollectRoadWarningSpans(segments, 400, true);
  TEST_EQUAL(spans.size(), 3, ());
  TEST(spans[0].type == Option::Toll, ());
  TEST_EQUAL(spans[0].firstSegment, 0, ());
  TEST_EQUAL(spans[0].distanceMeters, 50, ()); // Excludes the following ordinary segment.
  TEST(spans[1].type == Option::Ferry, ());
  TEST_EQUAL(spans[1].firstSegment, 3, ());
  TEST_EQUAL(spans[1].distanceMeters, 25, ());
  TEST(spans[2].type == Option::Dirty, ());
  TEST_EQUAL(spans[2].distanceMeters, 25, ());
  auto walking = routing::CollectRoadWarningSpans(segments, 400, false);
  TEST_EQUAL(walking.size(), 2, ()); // Existing non-car toll semantics retained.
  TEST(routing::CollectRoadWarningSpans({}, 0, true).empty(), ());
}

UNIT_TEST(NaviSnapshot_CopiesRoadWarningsWithoutRenderer)
{
  auto route = ShortRoute();
  auto segment = route.GetRouteSegments().front();
  routing::RoutingOptions options;
  options.Add(routing::RoutingOptions::Option::Toll);
  segment.SetRoadTypes(options);
  route.SetRouteSegments({segment});
  auto snapshot = navi::CaptureRoute(1, navi::RouteState::Preview, route, routing::FollowingInfo{});
  TEST_EQUAL(snapshot.roadWarnings.size(), 1, ());
  TEST(snapshot.roadWarnings[0].type == navi::RoadWarningType::Toll, ());
  TEST_EQUAL(snapshot.roadWarnings[0].position.latitude, 0, ());
  TEST_EQUAL(snapshot.roadWarnings[0].position.longitude, 0, ());
  TEST_EQUAL(snapshot.roadWarnings[0].distanceMeters, 0.111, ());
}

UNIT_TEST(NaviSnapshot_RejectsInvalidCoreMetrics)
{
  auto route = ShortRoute();
  auto segment = route.GetRouteSegments().front();
  segment.SetDistancesAndTime(0.111, 0.000001, std::numeric_limits<double>::infinity());
  route.SetRouteSegments({segment});
  auto snapshot = navi::CaptureRoute(17, navi::RouteState::Preview, route, routing::FollowingInfo{});
  TEST(snapshot.state == navi::RouteState::Failed, ());
  TEST_EQUAL(snapshot.revision, 17, ());
  TEST(snapshot.geometry.empty(), ());
  TEST(!snapshot.totalDistanceMeters && !snapshot.totalTimeSeconds, ());
  TEST(snapshot.errorCode != 0, ());
}
