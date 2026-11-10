#include "map/gps_track.hpp"
#include "map/navi_trip_store.hpp"
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
    requireRejectedRead(path + ".missing", archiveBytes.size());
    Require(!std::filesystem::exists(path + ".missing"), "reading a missing archive created a file");
    for (int invalid : {0, 1, 2}) {
      auto invalidBytes = archiveBytes;
      if (invalid == 0) invalidBytes[0] = 42;
      else if (invalid == 1) invalidBytes.pop_back();
      else invalidBytes[4 + 8 * sizeof(double)] = static_cast<char>(255);
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
    auto const tripRoot = std::filesystem::path(path + ".trips");
    std::string const id = "3fc70845-6c24-40af-ae36-dbd9dd80ba2b";
    std::string const emptyId = "3fc70845-6c24-40af-ae36-dbd9dd80ba2c";
    auto expectTripError = [](auto && action) {
      bool rejected = false;
      try { action(); } catch (std::exception const &) { rejected = true; }
      Require(rejected, "invalid trip operation was accepted");
    };
    {
      navi::TripStore store(tripRoot);
      expectTripError([&] { store.Begin("../other", navi::TripRole::Driver, 1000000); });
      store.Begin(id, navi::TripRole::Driver, 1000000);
      Require(store.List().empty(), "in-progress recording appeared in history");
      expectTripError([&] { store.Begin(emptyId, navi::TripRole::Passenger, 1000100); });
      expectTripError([&] { store.PrepareArchive(); });
    }
    {
      navi::TripStore reopened(tripRoot);
      auto const pending = reopened.Pending();
      Require(pending && pending->id == id && pending->startedAtMs == 1000000 &&
        pending->endedAtMs == 0 && pending->role == navi::TripRole::Driver, "pending trip did not survive reopening");
      reopened.Stop(1005000);
      reopened.Stop(1006000); // Retry keeps the original end time.
      auto destination = reopened.PrepareArchive();
      { std::ofstream interrupted(destination); interrupted << "partial"; }
      expectTripError([&] { reopened.PublishArchive(); });
      Require(reopened.Pending().has_value() && reopened.List().empty(), "failed export discarded the pending trip");
      destination = reopened.PrepareArchive();
      std::promise<bool> ready;
      {
        GpsTrack track(path);
        track.Clear();
        track.AddPoints({first, second});
        track.ExportSnapshot(destination.string(), [&](bool success) { ready.set_value(success); });
      }
      Require(ready.get_future().get() && reopened.PublishArchive(), "stopped trip archive was not published");
      Require(!reopened.Pending(), "successful publication left a pending trip");
    }
    {
      navi::TripStore history(tripRoot);
      auto const entries = history.List();
      Require(entries.size() == 1 && entries[0].id == id && entries[0].endedAtMs == 1005000,
        "stable trip metadata or original stop time was lost");
      auto const analysis = history.Load(id);
      Require(analysis.rawCount == 2 && analysis.distanceMeters > 50 &&
        analysis.maximumSpeedMetersPerSecond == 5, "archived GPS quality was not analysed");
      history.SetRole(id, navi::TripRole::Passenger);
      Require(navi::TripStore(tripRoot).List().front().role == navi::TripRole::Passenger,
        "role correction did not survive reopening");
      expectTripError([&] { history.Delete("../"); });
      expectTripError([&] { history.Begin(id, navi::TripRole::Driver, 1008000); });
      history.Begin(emptyId, navi::TripRole::Passenger, 1008000);
      history.Stop(1009000);
      auto const emptyDestination = history.PrepareArchive();
      std::promise<bool> ready;
      {
        GpsTrack track(path);
        track.Clear();
        track.ExportSnapshot(emptyDestination.string(), [&](bool success) { ready.set_value(success); });
      }
      Require(ready.get_future().get() && !history.PublishArchive(), "a recording without GPS points entered history");
      Require(!history.Pending() && history.List().size() == 1, "discarding an empty trip touched another trip");
      history.Delete(id);
      Require(navi::TripStore(tripRoot).List().empty(), "deleted trip reappeared after reopening");
    }
    std::filesystem::remove(archive);
    std::filesystem::remove(path);
    std::cout << "PASS real headless recorder progress, quality, reopen, callback attachment, detach, durable clear and ordered raw archives\n";
    std::cout << "PASS private trip history, interrupted archive retry, role correction and durable delete\n";
    return 0;
  } catch (std::exception const & error) {
    std::filesystem::remove(path);
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
