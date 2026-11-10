#pragma once
#include "geometry/latlon.hpp"
#include "platform/location.hpp"
#include <cstddef>
#include <optional>
#include <vector>

namespace navi {
enum class TripRejection { Source, Time, Position, Accuracy, Order, Jump };
struct RejectedTripPoint { size_t rawIndex; TripRejection reason; };
struct TripPoint { location::GpsInfo sample; size_t rawIndex; };
/// Uncalibrated GPS velocity derivative, not a safety or driving-style judgment.
struct TripVelocityChange {
  size_t fromIndex;
  size_t toIndex;
  double elapsedSeconds;
  double metersPerSecondSquared;
  double accuracyMeters;
};
struct TripAnalysis {
  unsigned qualityVersion = 1;
  size_t rawCount = 0;
  size_t gapCount = 0;
  size_t unknownSpeedSamples = 0;
  std::vector<RejectedTripPoint> rejected;
  std::vector<std::vector<TripPoint>> segments;
  std::vector<TripVelocityChange> velocityChanges;
  std::optional<double> maximumSpeedMetersPerSecond;
  double distanceMeters = 0;
  double coveredSeconds = 0;
  double startedAtSeconds = 0;
  double endedAtSeconds = 0;
};
struct TripGeometry {
  std::vector<std::vector<ms::LatLon>> segments;
  bool simplified = false;
};
/// Copies displayable measurements while preserving original indices and discontinuities.
/// Raw archives remain untouched. Quality version 1 has no calibrated event thresholds.
TripAnalysis AnalyseTrip(std::vector<location::GpsInfo> const & samples);
/// Keep real endpoints and separate drawable segments. No measurement
/// metadata is included in the resulting map geometry.
TripGeometry BuildTripGeometry(TripAnalysis const & analysis, size_t pointLimit, size_t segmentLimit);
}
