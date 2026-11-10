#pragma once

#include "map/gps_track.hpp"
#include "map/navi_trip_store.hpp"

#include <atomic>
#include <functional>
#include <utility>
#include <vector>

struct TrackStatistics;

namespace location
{
class GpsInfo;
}  // namespace location

class GpsTracker
{
public:
  static GpsTracker & Instance();

  bool IsEnabled() const;
  void SetEnabled(bool enabled);
  void Clear();

  bool IsEmpty() const;
  size_t GetTrackSize() const;
  TrackStatistics GetTrackStatistics() const;
  ElevationInfo GetElevationInfo() const;

  using TGpsTrackDiffCallback =
      std::function<void(std::vector<std::pair<size_t, location::GpsInfo>> && toAdd,
                         std::pair<size_t, size_t> const & toRemove, TrackStatistics const & trackStatistics)>;

  void Connect(TGpsTrackDiffCallback const & fn);
  void Disconnect();

  void OnLocationUpdated(location::GpsInfo const & info);
  /// Keeps the raw recorder available until the stopped trip is saved or can be retried.
  void ArchiveStoppedTrip(navi::TripStore & store, std::function<void(navi::TripArchiveResult)> completion);
  bool IsArchivingTrip() const { return m_archivingTrip; }

  using GpsTrackCallback = std::function<bool(location::GpsInfo const &, size_t)>;
  void ForEachTrackPoint(GpsTrackCallback const & callback) const;

private:
  GpsTracker();

  std::atomic<bool> m_enabled;
  std::atomic<bool> m_archivingTrip{false};
  GpsTrack m_track;
};
