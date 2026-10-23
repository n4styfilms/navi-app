#include "navi_test_platform.hpp"
#include "map/map_tests/navi_headless_routing_scenario.hpp"
#include <iostream>
#include <stdexcept>

int main(int argc, char ** argv)
{
  try
  {
    if (argc != 3) throw std::runtime_error("expected resource APK and writable map directory");
    InitNaviTestPlatform(argv[1], argv[2]);
    navi::testing::RunHeadlessRoutingScenario(argv[2], PumpNaviTestTasks);
    return 0;
  }
  catch (std::exception const & e)
  {
    std::cerr << "FAIL: " << e.what() << std::endl;
    return 1;
  }
}
