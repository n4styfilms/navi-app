#include "map/navi_route_capture.hpp"

#include "routing/following_info.hpp"
#include "routing/route.hpp"
#include "routing/road_warnings.hpp"
#include "geometry/mercator.hpp"

#include <cmath>

namespace navi
{
RouteSnapshot CaptureRoute(uint64_t revision, RouteState state, routing::Route const & route,
                           routing::FollowingInfo const & info, bool isCarRouter)
{
  RouteSnapshot result;
  result.revision = revision;
  result.state = state;
  if (!route.IsValid() || route.GetRouteSegments().empty())
  {
    result.state = RouteState::None;
    return result;
  }
  if (state != RouteState::Preview && state != RouteState::Navigating)
    return result;

  result.geometry.reserve(route.GetPoly().GetSize());
  for (auto const & point : route.GetPoly().GetPoints())
  {
    auto const latLon = mercator::ToLatLon(point);
    result.geometry.push_back({latLon.m_lat, latLon.m_lon});
  }
  result.totalDistanceMeters = route.GetTotalDistanceMeters();
  result.remainingDistanceMeters = route.GetCurrentDistanceToEndMeters();
  result.totalTimeSeconds = route.GetTotalTimeSec();
  result.remainingTimeSeconds = route.GetCurrentTimeToEndSec();
  result.street = info.m_currentStreetName;
  result.nextStreet = info.m_nextStreetName;
  result.nextTurn = static_cast<int>(info.m_turn);
  result.turnNotifications = info.m_turnNotifications;

  double turnDistance = 0;
  routing::turns::TurnItem turn;
  route.GetNearestTurn(turnDistance, turn);
  if (std::isfinite(turnDistance) && turnDistance >= 0)
    result.distanceToTurnMeters = turnDistance;
  if (std::isfinite(info.m_speedLimitMps) && info.m_speedLimitMps >= 0)
    result.speedLimitKmh = info.m_speedLimitMps * 3.6;
  auto const & segments = route.GetRouteSegments();
  for (auto const & span : routing::CollectRoadWarningSpans(segments, 0, isCarRouter))
  {
    auto const & position = span.firstSegment == 0 ? route.GetPoly().GetPoints().front() :
                                                    segments[span.firstSegment - 1].GetJunction().GetPoint();
    auto const latLon = mercator::ToLatLon(position);
    auto const type = span.type == routing::RoutingOptions::Option::Toll ? RoadWarningType::Toll :
                      span.type == routing::RoutingOptions::Option::Ferry ? RoadWarningType::Ferry :
                                                                           RoadWarningType::Unpaved;
    result.roadWarnings.push_back({type, {latLon.m_lat, latLon.m_lon}, span.distanceMeters});
  }
  if (!IsValidRouteSnapshot(result))
  {
    result = {};
    result.revision = revision;
    result.state = RouteState::Failed;
    result.errorCode = RouteSnapshot::kInvalidCoreData;
  }
  return result;
}
}
