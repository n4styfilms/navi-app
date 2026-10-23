#include "map/map_tests/navi_headless_routing_scenario.hpp"
#include "map/framework.hpp"
#include "map/routing_mark.hpp"
#include "platform/local_country_file.hpp"
#include "geometry/mercator.hpp"
#include "geometry/distance_on_sphere.hpp"
#include <cmath>
#include <iostream>
#include <iomanip>
#include <stdexcept>


namespace navi::testing
{
namespace
{
void RequireHeadless(bool condition, char const * message)
{
  if (!condition) throw std::runtime_error(message);
}
}
void RunHeadlessRoutingScenario(std::string const & dataDirectory, Pump const & pump)
{
    Framework framework(FrameworkParams(false), false /* loadMaps */);
    for (auto const * name : {"World", "Monaco", "France_Provence-Alpes-Cote dAzur_Maritime Alps"})
    {
      platform::LocalCountryFile map(dataDirectory, platform::CountryFile(name), 261004);
      map.SyncWithDisk();
      auto const registered = framework.RegisterMap(map);
      RequireHeadless(registered.first.IsAlive(), "real map registration failed");
    }
    auto & manager = framework.GetRoutingManager();
    auto empty = manager.GetRouteSnapshot();
    RequireHeadless(!empty.totalDistanceMeters, "no route must have absent distance");
    RouteMarkData start, finish;
    start.m_pointType = RouteMarkType::Start;
    start.m_position = mercator::FromLatLon(43.7295, 7.4208);
    // Exercise the actual mobile entry point: route from the provider's current
    // location, rather than two fixed pins (which concealed a missing position).
    start.m_isMyPosition = true;
    location::GpsInfo initialPosition;
    initialPosition.m_source = location::EAndroidNative;
    initialPosition.m_timestamp = 1699999990;
    initialPosition.m_latitude = 43.7295;
    initialPosition.m_longitude = 7.4208;
    initialPosition.m_horizontalAccuracy = 3;
    framework.OnLocationUpdate(initialPosition);
    finish.m_pointType = RouteMarkType::Finish;
    finish.m_position = mercator::FromLatLon(43.7450, 7.4270);
    manager.AddRoutePoint(std::move(start));
    manager.AddRoutePoint(std::move(finish));
    bool received = false;
    routing::RouterResultCode result = routing::RouterResultCode::InternalError;
    manager.SetRouteBuildingListener([&](auto code, auto const & absent)
    {
      for (auto const & name : absent) std::cout << "Absent map: " << name << std::endl;
      result = code;
      received = true;
    });
    manager.BuildRoute(30);
    auto building = manager.GetRouteSnapshot();
    RequireHeadless(building.state == navi::RouteState::Building && building.revision > empty.revision &&
            building.geometry.empty() && !building.totalDistanceMeters, "invalid building snapshot");
    RequireHeadless(pump([&] { return received; }, std::chrono::seconds(45)), "route callback timeout");
    std::cout << "Route result: " << static_cast<int>(result) << std::endl;
    RequireHeadless(result == routing::RouterResultCode::NoError || result == routing::RouterResultCode::HasWarnings,
            "real Monaco route failed");
    auto preview = manager.GetRouteSnapshot();
    RequireHeadless(preview.geometry.size() >= 2 && preview.totalDistanceMeters.value_or(0) > 0,
            "real route has no numeric geometry/distance");
    RequireHeadless(preview.state == navi::RouteState::Preview && preview.revision == building.revision,
            "route completion changed its request generation");
    std::cout << "Route: points=" << preview.geometry.size() << " meters=" << *preview.totalDistanceMeters
              << " seconds=" << *preview.totalTimeSeconds << " lights=" << preview.trafficLights.size() << std::endl;
    RequireHeadless(!preview.trafficLights.empty(), "rendererless traffic-light collection was skipped");
    manager.SetTurnNotificationsLocale("en");
    manager.SetTurnNotificationsUnits(measurement_utils::Units::Metric);
    manager.EnableTurnNotifications(true);
    manager.FollowRoute();
    RequireHeadless(manager.IsRoutingFollowing(), "rendererless route did not start");
    RequireHeadless(manager.GetRouteSnapshot().state == navi::RouteState::Navigating, "missing navigation state");
    auto const initialRemaining = *preview.remainingDistanceMeters;
    double timestamp = 1700000000;
    size_t locations = 0, spoken = 0;
    auto previous = preview.geometry.front();
    for (size_t i = 1; i < preview.geometry.size() / 2; ++i)
    {
      auto const & point = preview.geometry[i];
      if (ms::DistanceOnEarth(previous.latitude, previous.longitude, point.latitude, point.longitude) < 15)
        continue;
      location::GpsInfo gps;
      gps.m_source = location::EAndroidNative;
      gps.m_timestamp = timestamp += 12;
      gps.m_latitude = point.latitude;
      gps.m_longitude = point.longitude;
      gps.m_horizontalAccuracy = 3;
      gps.m_speed = 8;
      // Public synthetic route fixture for replaying the same journey in the
      // installed mobile app. No real user's location enters this test.
      std::cout << std::setprecision(12) << "Replay point: " << gps.m_latitude << " "
                << gps.m_longitude << std::endl;
      auto const before = manager.GetRouteSnapshot().remainingDistanceMeters.value_or(initialRemaining);
      framework.OnLocationUpdate(gps);
      RequireHeadless(pump([&]
      { return manager.GetRouteSnapshot().remainingDistanceMeters.value_or(initialRemaining) < before; },
                               std::chrono::seconds(2)), "GPS replay did not advance route");
      auto snapshot = manager.GetRouteSnapshot();
      RequireHeadless(snapshot.revision == preview.revision, "on-route GPS needlessly rebuilt geometry");
      manager.RoutingSession().RouteCall([&](routing::Route const & route)
      {
        double distance = 0;
        routing::turns::TurnItem turn;
        route.GetNearestTurn(distance, turn);
        RequireHeadless(snapshot.nextTurn == static_cast<int>(turn.m_turn), "snapshot maneuver differs from actual route");
        RequireHeadless(std::abs(snapshot.distanceToTurnMeters.value_or(-1) - distance) < 1e-8,
                "snapshot rounded maneuver distance");
      });
      std::vector<std::string> notifications;
      manager.GenerateNotifications(notifications, true);
      for (auto const & notification : notifications)
      {
        RequireHeadless(!notification.empty(), "empty TTS event");
        std::cout << "TTS: " << notification << std::endl;
        ++spoken;
      }
      previous = point;
      ++locations;
    }
    RequireHeadless(locations > 3 && spoken > 0, "GPS/voice replay had insufficient events");
    RequireHeadless(*manager.GetRouteSnapshot().remainingDistanceMeters < initialRemaining, "route did not progress");
    RequireHeadless(*preview.remainingDistanceMeters == initialRemaining, "old value snapshot was mutated");
    // Real off-route positions in the same region, increasingly distant from the matched point.
    auto const revisionBeforeDeviation = manager.GetRouteSnapshot().revision;
    for (size_t i = 0; i < 12 && manager.GetRouteSnapshot().revision == revisionBeforeDeviation; ++i)
    {
      location::GpsInfo gps;
      gps.m_source = location::EAndroidNative;
      gps.m_timestamp = timestamp += 12;
      gps.m_latitude = 43.737 + i * 0.0005;
      gps.m_longitude = 7.410 - i * 0.0003;
      gps.m_horizontalAccuracy = 3;
      gps.m_speed = 8;
      framework.OnLocationUpdate(gps);
      auto const until = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
      pump([&] { return std::chrono::steady_clock::now() >= until; }, std::chrono::seconds(1));
    }
    RequireHeadless(manager.GetRouteSnapshot().revision > revisionBeforeDeviation, "deviation did not initiate rerouting");
    RequireHeadless(pump([&] { return !manager.IsRouteBuilding(); }, std::chrono::seconds(45)),
            "reroute timeout");
    RequireHeadless(manager.IsRouteValid(), "real-map rerouting failed");
    auto const rebuilt = manager.GetRouteSnapshot();
    RequireHeadless(rebuilt.state == navi::RouteState::Navigating, "reroute lost navigation state");
    RequireHeadless(rebuilt.revision > preview.revision && !rebuilt.geometry.empty(), "reroute snapshot remained stale");
    // Traffic/GPS rebuilds deliberately omit external missing-map/remove callbacks.
    // Such a failure still has to finish and retain the usable previous route.
    bool rebuildFailureReceived = false;
    routing::RouterResultCode rebuildFailure = routing::RouterResultCode::NoError;
    manager.RoutingSession().RebuildRoute(mercator::FromLatLon(52.52, 13.405),
      [&](routing::Route const & route, routing::RouterResultCode code)
      {
        RequireHeadless(route.IsValid(), "failed rebuild discarded previous route");
        rebuildFailure = code;
        rebuildFailureReceived = true;
      }, nullptr, nullptr, 30, routing::SessionState::RouteRebuilding, true);
    RequireHeadless(pump([&] { return rebuildFailureReceived; }, std::chrono::seconds(10)),
                    "failed reroute never completed");
    RequireHeadless(rebuildFailure == routing::RouterResultCode::NeedMoreMaps, "wrong failed-reroute result");
    auto fallback = manager.GetRouteSnapshot();
    RequireHeadless(fallback.state == navi::RouteState::Navigating &&
                    fallback.totalDistanceMeters == rebuilt.totalDistanceMeters &&
                    fallback.geometry.size() == rebuilt.geometry.size(), "failed reroute lost usable navigation");
    auto const beforeMissingGps = fallback.revision;
    for (size_t i = 0; i < 12 && manager.GetRouteSnapshot().revision == beforeMissingGps; ++i)
    {
      location::GpsInfo gps;
      gps.m_source = location::EAndroidNative;
      gps.m_timestamp = timestamp += 12;
      gps.m_latitude = 52.52 + i * 0.001;
      gps.m_longitude = 13.405 + i * 0.001;
      gps.m_horizontalAccuracy = 3;
      gps.m_speed = 8;
      framework.OnLocationUpdate(gps);
      auto const until = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
      pump([&] { return std::chrono::steady_clock::now() >= until; }, std::chrono::seconds(1));
    }
    RequireHeadless(pump([&] { return manager.GetRouteSnapshot().errorCode != 0; }, std::chrono::seconds(10)),
                    "GPS-triggered missing-map rebuild did not report failure");
    auto const gpsFallback = manager.GetRouteSnapshot();
    RequireHeadless(gpsFallback.state == navi::RouteState::Navigating &&
                    gpsFallback.errorCode == static_cast<int>(routing::RouterResultCode::NeedMoreMaps) &&
                    gpsFallback.totalDistanceMeters == rebuilt.totalDistanceMeters &&
                    gpsFallback.revision > beforeMissingGps, "GPS rebuild failure hid usable navigation");
    std::cout << "PASS failed reroute keeps old navigation" << std::endl;
    manager.CloseRouting(true);
    auto cleared = manager.GetRouteSnapshot();
    RequireHeadless(cleared.state == navi::RouteState::None && cleared.geometry.empty() && !cleared.totalDistanceMeters &&
            cleared.revision > rebuilt.revision, "cancel did not invalidate geometry/metrics");
    // Start another request and cancel before queued worker results can run on the GUI thread.
    auto addPoint = [&](RouteMarkType type, navi::LatLon const & point)
    {
      RouteMarkData mark;
      mark.m_pointType = type;
      mark.m_position = mercator::FromLatLon(point.latitude, point.longitude);
      manager.AddRoutePoint(std::move(mark));
    };
    addPoint(RouteMarkType::Start, preview.geometry.front());
    addPoint(RouteMarkType::Finish, preview.geometry.back());
    manager.BuildRoute(30);
    manager.CloseRouting(true);
    auto const cancelledRevision = manager.GetRouteSnapshot().revision;
    auto const drainUntil = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    pump([&] { return std::chrono::steady_clock::now() >= drainUntil; }, std::chrono::seconds(2));
    auto afterLateResults = manager.GetRouteSnapshot();
    RequireHeadless(afterLateResults.revision == cancelledRevision && afterLateResults.state == navi::RouteState::None &&
            afterLateResults.geometry.empty() && !afterLateResults.totalDistanceMeters,
            "late worker result resurrected a cancelled route");
    addPoint(RouteMarkType::Start, preview.geometry.front());
    addPoint(RouteMarkType::Finish, {52.52, 13.405}); // Deliberately unavailable Berlin offline map.
    received = false;
    manager.BuildRoute(30);
    RequireHeadless(pump([&] { return received; }, std::chrono::seconds(45)), "missing-map callback timeout");
    RequireHeadless(result == routing::RouterResultCode::NeedMoreMaps, "missing-map error not preserved");
    auto failed = manager.GetRouteSnapshot();
    RequireHeadless(failed.state == navi::RouteState::Failed &&
            failed.errorCode == static_cast<int>(routing::RouterResultCode::NeedMoreMaps) &&
            failed.geometry.empty() && !failed.totalDistanceMeters, "failure remained building or retained cost input");
    manager.ResetRoutingSession();
    RequireHeadless(manager.GetRouteSnapshot().state == navi::RouteState::None &&
            manager.GetRouteSnapshot().revision > failed.revision, "session reset retained a previous error");
    std::cout << "Replay: GPS=" << locations << " TTS=" << spoken << std::endl;
    std::cout << "PASS real-map headless navigation, GPS, TTS, reroute, cancellation and failure" << std::endl;
}
}
