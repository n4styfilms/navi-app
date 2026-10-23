#include "map/navi_route_snapshot.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace navi
{
namespace
{
bool ValidPosition(LatLon const & point)
{
  return std::isfinite(point.latitude) && std::isfinite(point.longitude) &&
         point.latitude >= -90 && point.latitude <= 90 &&
         point.longitude >= -180 && point.longitude <= 180;
}

bool ValidMetric(std::optional<double> const & value)
{
  return value && std::isfinite(*value) && *value >= 0;
}

bool ValidSnapshot(RouteSnapshot const & snapshot)
{
  if (snapshot.state != RouteState::Preview && snapshot.state != RouteState::Navigating)
    return false;
  if (snapshot.geometry.size() < 2 ||
      !std::all_of(snapshot.geometry.begin(), snapshot.geometry.end(), ValidPosition))
    return false;
  if (!ValidMetric(snapshot.totalDistanceMeters) || !ValidMetric(snapshot.remainingDistanceMeters) ||
      !ValidMetric(snapshot.totalTimeSeconds) || !ValidMetric(snapshot.remainingTimeSeconds))
    return false;
  if ((snapshot.speedLimitKmh && !ValidMetric(snapshot.speedLimitKmh)) ||
      (snapshot.distanceToTurnMeters && !ValidMetric(snapshot.distanceToTurnMeters)))
    return false;
  return std::all_of(snapshot.roadWarnings.begin(), snapshot.roadWarnings.end(), [](auto const & warning)
  {
    return ValidPosition(warning.position) && std::isfinite(warning.distanceMeters) && warning.distanceMeters >= 0;
  }) && std::all_of(snapshot.trafficLights.begin(), snapshot.trafficLights.end(), ValidPosition);
}
}  // namespace

bool IsValidRouteSnapshot(RouteSnapshot const & snapshot)
{
  return ValidSnapshot(snapshot);
}

void RouteSnapshotStore::Reset(RouteState state)
{
  if (m_snapshot.revision == std::numeric_limits<uint64_t>::max())
    throw std::overflow_error("Route revision exhausted");
  auto const revision = m_snapshot.revision + 1;
  m_snapshot = {};
  m_snapshot.revision = revision;
  m_snapshot.state = state;
}

uint64_t RouteSnapshotStore::BeginBuild()
{
  Reset(RouteState::Building);
  return m_snapshot.revision;
}

void RouteSnapshotStore::Clear()
{
  Reset(RouteState::None);
}

bool RouteSnapshotStore::Publish(uint64_t revision, RouteSnapshot snapshot)
{
  if (revision != m_snapshot.revision || m_snapshot.state != RouteState::Building || !IsValidRouteSnapshot(snapshot))
    return false;
  snapshot.revision = revision;
  m_snapshot = std::move(snapshot);
  return true;
}

bool RouteSnapshotStore::Fail(uint64_t revision, int errorCode)
{
  if (revision != m_snapshot.revision || m_snapshot.state != RouteState::Building)
    return false;
  m_snapshot = {};
  m_snapshot.revision = revision;
  m_snapshot.state = RouteState::Failed;
  m_snapshot.errorCode = errorCode;
  return true;
}
}  // namespace navi
