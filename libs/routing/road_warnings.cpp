#include "routing/road_warnings.hpp"
#include "routing/route.hpp"

namespace routing
{
std::vector<RoadWarningSpan> CollectRoadWarningSpans(std::vector<RouteSegment> const & segments,
                                                     double baseDistanceMeters, bool isCarRouter)
{
  std::vector<RoadWarningSpan> result;
  auto previousType = RoutingOptions::Option::Usual;
  double previousDistance = baseDistanceMeters;
  for (size_t i = 0; i < segments.size(); ++i)
  {
    auto const & segment = segments[i];
    auto const type = ChooseMainRoutingOption(segment.GetRoadTypes(), isCarRouter);
    bool const warned = type == RoutingOptions::Option::Toll || type == RoutingOptions::Option::Ferry ||
                        type == RoutingOptions::Option::Dirty;
    if (warned)
    {
      if (type != previousType)
        result.push_back({type, i, 0});
      result.back().distanceMeters += segment.GetDistFromBeginningMeters() - previousDistance;
    }
    previousType = type;
    previousDistance = segment.GetDistFromBeginningMeters();
  }
  return result;
}
}
