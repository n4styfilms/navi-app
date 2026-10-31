#include "map/navi_trip_analysis.hpp"
#include "geometry/distance_on_sphere.hpp"
#include <algorithm>
#include <cmath>

namespace navi {
namespace {
// Prototype display-quality bounds; these do not classify driving safety.
double constexpr kAccuracyLimit = 50;
double constexpr kGapSeconds = 15;
double constexpr kPlausibleSpeed = 120;
double constexpr kDerivativeAccuracy = 15;
std::optional<TripRejection> Invalid(location::GpsInfo const & point) {
  if (point.m_source != location::EAppleNative && point.m_source != location::EAndroidNative)
    return TripRejection::Source;
  if (!std::isfinite(point.m_timestamp) || point.m_timestamp <= 0 || point.m_timestamp > 9'007'199'254'740.0)
    return TripRejection::Time;
  if (!std::isfinite(point.m_latitude) || !std::isfinite(point.m_longitude)
      || point.m_latitude < -90 || point.m_latitude > 90 || point.m_longitude < -180 || point.m_longitude > 180)
    return TripRejection::Position;
  if (!std::isfinite(point.m_horizontalAccuracy) || point.m_horizontalAccuracy < 0
      || point.m_horizontalAccuracy > kAccuracyLimit)
    return TripRejection::Accuracy;
  return {};
}
bool KnownSpeed(double speed) { return std::isfinite(speed) && speed >= 0 && speed <= kPlausibleSpeed; }
}
TripAnalysis AnalyseTrip(std::vector<location::GpsInfo> const & samples) {
  TripAnalysis result;
  result.rawCount = samples.size();
  bool discontinuity = true;
  for (size_t index = 0; index < samples.size(); ++index) {
    auto point = samples[index];
    auto reject = [&](TripRejection reason) {
      result.rejected.push_back({index, reason}); discontinuity = true;
    };
    if (auto reason = Invalid(point)) { reject(*reason); continue; }
    TripPoint const * previous = result.segments.empty() ? nullptr : &result.segments.back().back();
    if (previous && point.m_timestamp <= previous->sample.m_timestamp) { reject(TripRejection::Order); continue; }
    double const elapsed = previous ? point.m_timestamp - previous->sample.m_timestamp : 0;
    bool const continuous = previous && !discontinuity && elapsed <= kGapSeconds
      && previous->sample.m_source == point.m_source;
    double distance = 0;
    if (continuous) {
      distance = ms::DistanceOnEarth(previous->sample.m_latitude, previous->sample.m_longitude,
        point.m_latitude, point.m_longitude);
      double const lowerBound = std::max(0.0, distance - previous->sample.m_horizontalAccuracy - point.m_horizontalAccuracy);
      if (lowerBound / elapsed > kPlausibleSpeed) { reject(TripRejection::Jump); continue; }
    }
    bool const knownSpeed = KnownSpeed(point.m_speed);
    if (!knownSpeed) { point.m_speed = -1; ++result.unknownSpeedSamples; }
    else if (!result.maximumSpeedMetersPerSecond || point.m_speed > *result.maximumSpeedMetersPerSecond)
      result.maximumSpeedMetersPerSecond = point.m_speed;
    if (continuous) {
      result.distanceMeters += distance;
      result.coveredSeconds += elapsed;
      if (knownSpeed && KnownSpeed(previous->sample.m_speed) && elapsed >= 0.5 && elapsed <= 5
          && point.m_horizontalAccuracy <= kDerivativeAccuracy && previous->sample.m_horizontalAccuracy <= kDerivativeAccuracy) {
        result.velocityChanges.push_back({previous->rawIndex, index, elapsed,
          (point.m_speed - previous->sample.m_speed) / elapsed,
          std::max(point.m_horizontalAccuracy, previous->sample.m_horizontalAccuracy)});
      }
    } else {
      if (!result.segments.empty()) ++result.gapCount;
      result.segments.emplace_back();
    }
    if (result.segments.size() == 1 && result.segments.front().empty()) result.startedAtSeconds = point.m_timestamp;
    result.endedAtSeconds = point.m_timestamp;
    result.segments.back().push_back({point, index});
    discontinuity = false;
  }
  return result;
}
}
