#include "map/map_tests/navi_headless_routing_scenario.hpp"
#include "platform/platform.hpp"
#include "testing/testing.hpp"
#include <QCoreApplication>
#include <QEventLoop>
#include <chrono>
#include <thread>

UNIT_TEST(NaviHeadless_RealMapNavigationReplay)
{
  navi::testing::RunHeadlessRoutingScenario(GetPlatform().WritableDir(),
    [](std::function<bool()> const & done, std::chrono::seconds timeout)
    {
      auto const deadline = std::chrono::steady_clock::now() + timeout;
      while (!done() && std::chrono::steady_clock::now() < deadline)
      {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      return done();
    });
}
