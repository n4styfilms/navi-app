#pragma once

#include "map/navi_route_snapshot.hpp"

namespace routing
{
class Route;
class FollowingInfo;
}

namespace navi
{
// Called while the routing session owns the route on its GUI thread.
// Copies numeric core data; never parses rounded/localized display distances.
RouteSnapshot CaptureRoute(uint64_t revision, RouteState state, routing::Route const & route,
                           routing::FollowingInfo const & info, bool isCarRouter = true);
}
