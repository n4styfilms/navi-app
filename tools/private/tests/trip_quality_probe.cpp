#include "map/navi_trip_analysis.hpp"
#include "geometry/distance_on_sphere.hpp"
#include <cmath>
#include <iostream>
#include <limits>
#include <numbers>
#include <stdexcept>

namespace {
void Require(bool value, char const * reason) { if (!value) throw std::runtime_error(reason); }
location::GpsInfo Point(double time, double meters, double speed) {
  location::GpsInfo point;
  point.m_source = location::EAppleNative; point.m_timestamp = time;
  point.m_latitude = 0; point.m_longitude = meters / ms::kEarthRadiusMeters * 180 / std::numbers::pi;
  point.m_horizontalAccuracy = 4; point.m_speed = speed;
  return point;
}
}
int main() {
  try {
    double const nan = std::numeric_limits<double>::quiet_NaN();
    double const infinity = std::numeric_limits<double>::infinity();
    auto first = Point(1000, 0, 10), middle = Point(1002, 20, 20), last = Point(1004, 60, 10);
    auto empty = navi::AnalyseTrip({});
    Require(empty.rawCount == 0 && empty.segments.empty() && !empty.maximumSpeedMetersPerSecond,
      "Empty trip invented metrics");
    auto normal = navi::AnalyseTrip({first, middle, last});
    Require(normal.rawCount == 3 && normal.rejected.empty() && normal.gapCount == 0 && normal.segments.size() == 1,
      "Valid native trip lost continuity");
    Require(std::abs(normal.distanceMeters - 60) < 0.05 && normal.coveredSeconds == 4
      && normal.startedAtSeconds == 1000 && normal.endedAtSeconds == 1004,
      "Trip distance or time changed");
    Require(normal.maximumSpeedMetersPerSecond == 20 && normal.velocityChanges.size() == 2,
      "Known GPS speed or derivative missing");
    Require(normal.velocityChanges[0].metersPerSecondSquared == 5 && normal.velocityChanges[1].metersPerSecondSquared == -5
      && normal.velocityChanges[0].fromIndex == 0 && normal.velocityChanges[0].toIndex == 1,
      "GPS acceleration interval changed or lost original sample indices");
    for (int invalid = 0; invalid < 9; ++invalid) {
      auto bad = middle;
      if (invalid == 0) bad.m_latitude = nan;
      if (invalid == 1) bad.m_timestamp = infinity;
      if (invalid == 2) bad.m_horizontalAccuracy = -1;
      if (invalid == 3) bad.m_horizontalAccuracy = 51;
      if (invalid == 4) bad.m_timestamp = first.m_timestamp;
      if (invalid == 5) bad.m_timestamp = first.m_timestamp - 1;
      if (invalid == 6) bad.m_source = location::EPredictor;
      if (invalid == 7) bad.m_longitude = 181;
      if (invalid == 8) bad.m_longitude = 2;
      auto result = navi::AnalyseTrip({first, bad, last});
      Require(result.rejected.size() == 1 && result.gapCount == 1 && result.segments.size() == 2
        && result.distanceMeters == 0 && result.coveredSeconds == 0 && result.velocityChanges.empty(),
        "Bad fix created distance, acceleration or a line across a gap");
      Require(result.segments.back().front().rawIndex == 2, "Analysis reordered original samples");
    }
    auto late = middle; late.m_timestamp = 1040;
    auto tunnel = navi::AnalyseTrip({first, late});
    Require(tunnel.gapCount == 1 && tunnel.distanceMeters == 0 && tunnel.velocityChanges.empty(),
      "Tunnel gap was connected");
    auto android = middle; android.m_source = location::EAndroidNative;
    auto mixed = navi::AnalyseTrip({first, android});
    Require(mixed.gapCount == 1 && mixed.velocityChanges.empty(), "Provider change created an acceleration interval");
    for (double unknown : {-1.0, nan, infinity, 121.0}) {
      auto a = first, b = middle; a.m_speed = b.m_speed = unknown;
      auto result = navi::AnalyseTrip({a, b});
      Require(!result.maximumSpeedMetersPerSecond && result.unknownSpeedSamples == 2 && result.velocityChanges.empty()
        && result.segments.front().front().sample.m_speed == -1,
        "Missing velocity became stopped, a peak or a driving event");
    }
    auto noisy = middle; noisy.m_horizontalAccuracy = 20;
    Require(navi::AnalyseTrip({first, noisy}).velocityChanges.empty(), "Low-quality velocity was graded");
    auto shortStep = middle; shortStep.m_timestamp = 1000.25;
    auto longStep = middle; longStep.m_timestamp = 1006;
    Require(navi::AnalyseTrip({first, shortStep}).velocityChanges.empty()
      && navi::AnalyseTrip({first, longStep}).velocityChanges.empty(), "Unsupported derivative span was accepted");
    std::cout << "PASS trip quality scenarios: gaps, timestamps, source, finite bounds, unknown velocity and raw GPS intervals\n";
    return 0;
  } catch (std::exception const & error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
}
