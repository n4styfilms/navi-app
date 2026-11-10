#include "map/navi_trip_store.hpp"

#include "map/gps_track_storage.hpp"

#include <algorithm>
#include <fstream>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace navi
{
namespace
{
namespace fs = std::filesystem;
char constexpr kPending[] = ".pending";
char constexpr kArchive[] = "track.bin";
char constexpr kMetadata[] = "trip.txt";
char constexpr kFormat[] = "navi-trip-v1";

bool IsTripId(std::string_view id)
{
  if (id.size() != 36)
    return false;
  for (size_t i = 0; i < id.size(); ++i)
  {
    char const value = id[i];
    if (i == 8 || i == 13 || i == 18 || i == 23)
    {
      if (value != '-')
        return false;
    }
    else if (!(value >= '0' && value <= '9') && !(value >= 'a' && value <= 'f'))
    {
      return false;
    }
  }
  return true;
}

char const * RoleName(TripRole role)
{
  switch (role)
  {
  case TripRole::Driver: return "driver";
  case TripRole::Passenger: return "passenger";
  }
  throw std::runtime_error("Invalid trip role");
}

TripMetadata ReadMetadata(fs::path const & directory)
{
  auto const path = directory / kMetadata;
  if (fs::file_size(path) > 256)
    throw std::runtime_error("Oversized trip metadata");

  TripMetadata trip{};
  std::string format, role, extra;
  std::ifstream input(path);
  if (!(input >> format >> trip.id >> role >> trip.startedAtMs >> trip.endedAtMs) ||
      format != kFormat || !IsTripId(trip.id) || trip.startedAtMs <= 0 ||
      (trip.endedAtMs != 0 && trip.endedAtMs < trip.startedAtMs) || (input >> extra))
    throw std::runtime_error("Invalid trip metadata");
  if (role == "driver")
    trip.role = TripRole::Driver;
  else if (role == "passenger")
    trip.role = TripRole::Passenger;
  else
    throw std::runtime_error("Invalid stored trip role");
  return trip;
}

void WriteMetadata(fs::path const & directory, TripMetadata const & trip)
{
  auto const temporary = directory / "trip.tmp";
  char const * role = RoleName(trip.role);
  std::ofstream output(temporary, std::ios::trunc);
  output << kFormat << '\n' << trip.id << '\n' << role << '\n' << trip.startedAtMs << '\n' << trip.endedAtMs << '\n';
  output.close();
  if (!output)
    throw std::runtime_error("Cannot write trip metadata");
  fs::rename(temporary, directory / kMetadata);
}
}  // namespace

TripStore::TripStore(fs::path root) : m_root(std::move(root)) {}

fs::path TripStore::TripDirectory(std::string const & id) const
{
  if (!IsTripId(id))
    throw std::runtime_error("Invalid trip ID");
  return m_root / id;
}

void TripStore::Begin(std::string const & id, TripRole role, int64_t startedAtMs)
{
  if (startedAtMs <= 0 || fs::exists(TripDirectory(id)) || fs::exists(m_root / kPending))
    throw std::runtime_error("Cannot begin trip");
  auto const staging = m_root / ".begin";
  fs::create_directories(staging);
  WriteMetadata(staging, {id, role, startedAtMs, 0});
  fs::rename(staging, m_root / kPending);
}

std::optional<TripMetadata> TripStore::Pending() const
{
  auto const directory = m_root / kPending;
  if (!fs::exists(directory))
    return {};
  return ReadMetadata(directory);
}

void TripStore::Stop(int64_t endedAtMs)
{
  auto trip = Pending();
  if (!trip || endedAtMs < trip->startedAtMs)
    throw std::runtime_error("Cannot stop trip");
  if (trip->endedAtMs == 0)
  {
    trip->endedAtMs = endedAtMs;
    WriteMetadata(m_root / kPending, *trip);
  }
}

TripMetadata TripStore::StoppedTrip() const
{
  auto trip = Pending();
  if (!trip || trip->endedAtMs == 0)
    throw std::runtime_error("Stop the trip before archiving");
  return *trip;
}

fs::path TripStore::PrepareArchive()
{
  StoppedTrip();
  auto const path = m_root / kPending / kArchive;
  fs::remove(path);
  return path;
}

bool TripStore::PublishArchive()
{
  auto const trip = StoppedTrip();
  auto const pending = m_root / kPending;
  auto const destination = TripDirectory(trip.id);
  if (fs::exists(destination))
    throw std::runtime_error("Trip already exists");
  if (GpsTrackStorage::ReadSnapshot((pending / kArchive).string()).empty())
  {
    fs::remove_all(pending);
    return false;
  }
  fs::rename(pending, destination);
  return true;
}

std::vector<TripMetadata> TripStore::List() const
{
  std::vector<TripMetadata> result;
  if (!fs::exists(m_root))
    return result;
  for (auto const & entry : fs::directory_iterator(m_root))
  {
    auto const id = entry.path().filename().string();
    if (!IsTripId(id) || !entry.is_directory() || !fs::is_regular_file(entry.path() / kArchive))
      continue;
    auto trip = ReadMetadata(entry.path());
    if (trip.id != id || trip.endedAtMs == 0)
      throw std::runtime_error("Invalid archived trip identity");
    result.push_back(std::move(trip));
  }
  std::ranges::sort(result, [](TripMetadata const & left, TripMetadata const & right)
  {
    if (left.startedAtMs != right.startedAtMs)
      return left.startedAtMs > right.startedAtMs;
    return left.id < right.id;
  });
  return result;
}

TripAnalysis TripStore::Load(std::string const & id) const
{
  return AnalyseTrip(GpsTrackStorage::ReadSnapshot((TripDirectory(id) / kArchive).string()));
}

void TripStore::SetRole(std::string const & id, TripRole role)
{
  auto const directory = TripDirectory(id);
  auto trip = ReadMetadata(directory);
  if (trip.id != id || trip.endedAtMs == 0)
    throw std::runtime_error("Invalid archived trip identity");
  trip.role = role;
  WriteMetadata(directory, trip);
}

void TripStore::Delete(std::string const & id)
{
  fs::remove_all(TripDirectory(id));
}
}  // namespace navi
