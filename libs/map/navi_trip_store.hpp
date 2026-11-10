#pragma once

#include "map/navi_trip_analysis.hpp"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace navi
{
enum class TripRole { Driver, Passenger };

struct TripMetadata
{
  std::string id;
  TripRole role;
  int64_t startedAtMs;
  int64_t endedAtMs;  // Zero while the recording is active.
};

/// One local trip recorder owns this private directory. Serialize store calls
/// and wait for the recorder's export callback before publishing or retrying.
class TripStore
{
public:
  explicit TripStore(std::filesystem::path root);
  void Begin(std::string const & id, TripRole role, int64_t startedAtMs);
  std::optional<TripMetadata> Pending() const;
  void Stop(int64_t endedAtMs);
  /// Returns a fresh destination for GpsTrack::ExportSnapshot. Retrying discards
  /// the previous unpublished copy. The recorder's original data is untouched.
  std::filesystem::path PrepareArchive();
  /// Call after a successful recorder export. Returns false for an empty trip.
  bool PublishArchive();

  std::vector<TripMetadata> List() const;
  TripAnalysis Load(std::string const & id) const;
  void SetRole(std::string const & id, TripRole role);
  void Delete(std::string const & id);

private:
  TripMetadata StoppedTrip() const;
  std::filesystem::path TripDirectory(std::string const & id) const;
  std::filesystem::path m_root;
};
}  // namespace navi
