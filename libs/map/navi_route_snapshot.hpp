#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace navi
{
enum class RouteState : uint8_t { None, Building, Preview, Navigating, Failed };

struct LatLon
{
  double latitude = 0;
  double longitude = 0;
};

enum class RoadWarningType : uint8_t { Toll, Ferry, Unpaved };

struct RoadWarning
{
  RoadWarningType type;
  LatLon position;
  double distanceMeters = 0;
};

// Value-only boundary: no route, engine, feature, or platform-owned pointers.
// Missing metrics stay missing, rather than becoming a fictitious zero route.
struct RouteSnapshot
{
  static constexpr int kInvalidCoreData = -1;
  uint64_t revision = 0;
  RouteState state = RouteState::None;
  std::vector<LatLon> geometry;
  std::optional<double> totalDistanceMeters;
  std::optional<double> remainingDistanceMeters;
  std::optional<double> totalTimeSeconds;
  std::optional<double> remainingTimeSeconds;
  std::optional<double> distanceToTurnMeters;
  std::optional<double> speedLimitKmh;
  int nextTurn = 0;
  std::string street;
  std::string nextStreet;
  std::vector<std::string> turnNotifications;
  std::vector<RoadWarning> roadWarnings;
  std::vector<LatLon> trafficLights;
  int errorCode = 0;
};

bool IsValidRouteSnapshot(RouteSnapshot const & snapshot);

// Owned and called on the router GUI thread. Consumers receive independent copies.
// A request's revision must accompany its completion, including failed completions.
class RouteSnapshotStore
{
public:
  uint64_t BeginBuild();
  void Clear();
  bool Publish(uint64_t revision, RouteSnapshot snapshot);
  bool Fail(uint64_t revision, int errorCode);
  RouteSnapshot Read() const { return m_snapshot; }

private:
  void Reset(RouteState state);
  RouteSnapshot m_snapshot;
};
}  // namespace navi
