#include "map/gps_track.hpp"
#include "map/gps_track_storage.hpp"
#include "map/track_statistics.hpp"
#include <atomic>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <thread>

namespace {
void Require(bool condition, char const * message) {
  if (!condition) throw std::runtime_error(message);
}
template <typename F> bool Wait(F && condition) {
  auto const deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (!condition() && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  return condition();
}
}
int main(int argc, char ** argv) {
  if (argc != 2) return 2;
  std::string const path = argv[1];
  try {
    location::GpsInfo first;
    first.m_timestamp = 1000; first.m_latitude = 43.7295; first.m_longitude = 7.4208;
    first.m_speed = 5; first.m_horizontalAccuracy = 4; first.m_source = location::EAppleNative;
    auto second = first; second.m_timestamp += 1; second.m_longitude += 0.001;
    {
      GpsTrack track(path);
      track.AddPoints({first, second});
      Require(Wait([&] { return track.GetSize() == 2; }), "headless recorder did not expose recorded progress");
      Require(!track.IsEmpty() && track.GetTrackStatistics().m_length > 50, "headless recording is empty or has no distance");
    }
    {
      // The callback and its captured state outlive the real worker's join.
      std::atomic<size_t> snapshotSize{0};
      GpsTrack restored(path);
      restored.AddPoints({});
      Require(Wait([&] { return restored.GetSize() == 2; }), "headless storage did not restore progress");
      size_t count = 0;
      restored.ForEachPoint([&](location::GpsInfo const & point, size_t) {
        ++count;
        Require(point.m_source == location::EAppleNative && point.m_horizontalAccuracy == 4 && point.m_speed == 5,
          "measurement quality changed on storage reopen");
        return true;
      });
      Require(count == 2, "headless point snapshot missing");
      restored.SetCallback([&](auto && points, auto const &, TrackStatistics const &) { snapshotSize = points.size(); });
      Require(Wait([&] { return snapshotSize == 2; }), "late drawing callback did not receive existing points");
      restored.SetCallback(nullptr);
      auto third = second; third.m_timestamp += 1; third.m_longitude += 0.001;
      restored.AddPoint(third);
      Require(Wait([&] { return restored.GetSize() == 3; }), "detaching drawing stopped recording progress");
      restored.Clear();
      Require(Wait([&] { return restored.GetSize() == 0; }), "headless clear failed");
    }
    GpsTrackStorage storage(path);
    size_t remaining = 0;
    storage.ForEach([&](auto const &) { ++remaining; return true; });
    Require(remaining == 0, "cleared points returned after reopen");
    std::filesystem::remove(path);
    std::cout << "PASS real headless recorder progress, quality, reopen, callback attachment, detach and durable clear\n";
    return 0;
  } catch (std::exception const & error) {
    std::filesystem::remove(path);
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
