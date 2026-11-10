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

TripGeometry BuildTripGeometry(TripAnalysis const & analysis, size_t pointLimit, size_t segmentLimit) {
  TripGeometry result;
  std::vector<std::vector<TripPoint> const *> drawable;
  for (auto const & segment : analysis.segments) {
    if (segment.size() >= 2) drawable.push_back(&segment);
  }
  size_t const count = std::min({drawable.size(), segmentLimit, pointLimit / 2});
  result.simplified = count < drawable.size();
  if (count == 0) return result;

  auto sampleIndex = [](size_t index, size_t sampleCount, size_t sourceCount) {
    return static_cast<size_t>(static_cast<uint64_t>(index) * (sourceCount - 1) / (sampleCount - 1));
  };
  std::vector<std::vector<TripPoint> const *> selected;
  if (count == 1) {
    selected.push_back(*std::max_element(drawable.begin(), drawable.end(),
      [](auto const * left, auto const * right) { return left->size() < right->size(); }));
  } else {
    for (size_t i = 0; i < count; ++i) selected.push_back(drawable[sampleIndex(i, count, drawable.size())]);
  }
  size_t interiors = 0;
  for (auto const * segment : selected) interiors += segment->size() - 2;
  size_t budget = pointLimit - 2 * count;
  for (auto const * segment : selected) {
    size_t const available = segment->size() - 2;
    size_t const keep = interiors <= budget ? available
      : static_cast<size_t>(static_cast<uint64_t>(budget) * available / interiors);
    budget -= keep;
    interiors -= available;
    result.simplified = result.simplified || keep < available;
    auto & coordinates = result.segments.emplace_back();
    coordinates.reserve(keep + 2);
    for (size_t i = 0; i < keep + 2; ++i) {
      auto const & sample = (*segment)[sampleIndex(i, keep + 2, segment->size())].sample;
      coordinates.emplace_back(sample.m_latitude, sample.m_longitude);
    }
  }
  return result;
}
}
