#pragma once
#include "routing/routing_options.hpp"
#include <cstddef>
#include <vector>

namespace routing
{
class RouteSegment;
struct RoadWarningSpan
{
  RoutingOptions::Option type;
  size_t firstSegment;
  double distanceMeters;
};

// Segment end distances are cumulative along the whole route. The base is the
// distance before this subroute, in meters. Shared by renderer and native DTOs.
std::vector<RoadWarningSpan> CollectRoadWarningSpans(std::vector<RouteSegment> const & segments,
                                                     double baseDistanceMeters, bool isCarRouter);
}
