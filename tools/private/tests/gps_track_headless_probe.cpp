#include "map/gps_track.hpp"
#include "map/gps_track_storage.hpp"
#include "map/track_statistics.hpp"
#include <atomic>
#include <chrono>
#include <filesystem>
#include <future>
#include <fstream>
#include <iterator>
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
    auto countStored = [](std::string const & file) {
      GpsTrackStorage storage(file);
      size_t count = 0;
      storage.ForEach([&](auto const &) { ++count; return true; });
      return count;
    };
    Require(countStored(path) == 0, "cleared points returned after reopen");
    auto const archive = path + ".archive";
    std::promise<bool> exported;
    auto exportedResult = exported.get_future();
    {
      GpsTrack track(path);
      track.AddPoints({first, second});
      track.ExportSnapshot(archive, [&](bool success) { exported.set_value(success); });
      // A following trip must not clear the previous trip's pending archive.
      track.Clear();
      auto nextTrip = second; nextTrip.m_timestamp += 10;
      track.AddPoint(nextTrip);
    } // Destruction must finish accepted points and snapshot callbacks.
    Require(exportedResult.wait_for(std::chrono::seconds(0)) == std::future_status::ready && exportedResult.get(),
      "queued archive was not completed during shutdown");
    Require(countStored(archive) == 2 && countStored(path) == 1,
      "next recording clear changed the previous raw archive");
    auto readBytes = [](std::string const & file) {
      std::ifstream input(file, std::ios::binary);
      return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
    };
    auto const archiveBytes = readBytes(archive);
    {
      auto const preserved = GpsTrackStorage::ReadSnapshot(archive, archiveBytes.size());
      Require(preserved.size() == 2, "read-only archive lost points");
      for (auto const & point : preserved) {
        Require(point.m_speed == 5 && point.m_horizontalAccuracy == 4 && point.m_source == location::EAppleNative,
          "archive lost raw speed, accuracy or device source");
      }
    }
    auto requireRejectedRead = [&](std::string const & file, size_t limit) {
      bool rejected = false;
      try { (void)GpsTrackStorage::ReadSnapshot(file, limit); }
      catch (GpsTrackStorage::ReadException const &) { rejected = true; }
      Require(rejected, "invalid or oversized raw archive was accepted");
    };
    requireRejectedRead(archive, archiveBytes.size() - 1);
    Require(readBytes(archive) == archiveBytes, "size rejection changed the raw archive");
    for (bool truncated : {false, true}) {
      auto invalidBytes = archiveBytes;
      if (truncated) invalidBytes.pop_back(); else invalidBytes[0] = 42;
      auto const invalidPath = path + ".invalid";
      { std::ofstream output(invalidPath, std::ios::binary); output.write(invalidBytes.data(), invalidBytes.size()); }
      requireRejectedRead(invalidPath, archiveBytes.size());
      Require(readBytes(invalidPath) == invalidBytes, "invalid archive was rewritten while reading");
      std::filesystem::remove(invalidPath);
    }
    std::promise<bool> overwrite, alias;
    auto overwriteResult = overwrite.get_future(), aliasResult = alias.get_future();
    {
      GpsTrack track(path);
      track.ExportSnapshot(archive, [&](bool success) { overwrite.set_value(success); });
      track.ExportSnapshot(path, [&](bool success) { alias.set_value(success); });
    }
    Require(!overwriteResult.get() && !aliasResult.get(), "raw archive export overwrote an existing recording");
    Require(countStored(archive) == 2 && countStored(path) == 1, "failed export damaged existing points");
    std::filesystem::remove(archive);
    std::filesystem::remove(path);
    std::cout << "PASS real headless recorder progress, quality, reopen, callback attachment, detach, durable clear and ordered raw archives\n";
    return 0;
  } catch (std::exception const & error) {
    std::filesystem::remove(path);
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
