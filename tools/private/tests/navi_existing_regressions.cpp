// Re-run the actual cases discovered in the full Linux suites on Android.
// This focused executable supplements, and never replaces, the full suites.
#include "navi_test_platform.hpp"
#include "testing/testing.hpp"
#include "base/math.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>

namespace
{
void RequireExisting(bool value, char const * expression)
{
  if (!value) throw std::runtime_error(expression);
}
}
#undef UNIT_TEST
#undef TEST
#undef TEST_EQUAL
#undef TEST_ALMOST_EQUAL_ABS
#undef TEST_ALMOST_EQUAL_ULPS
#define UNIT_TEST(name) void UnitTest_##name()
#define TEST(value, message) RequireExisting(static_cast<bool>(value), #value)
#define TEST_EQUAL(left, right, message) RequireExisting((left) == (right), #left " == " #right)
#define TEST_ALMOST_EQUAL_ABS(left, right, epsilon, message) RequireExisting(AlmostEqualAbs(left, right, epsilon), #left " ~= " #right)
#define TEST_ALMOST_EQUAL_ULPS(left, right, message) RequireExisting(AlmostEqualULPs(left, right), #left " ~= " #right)
#include "map/map_tests/chart_generator_tests.cpp"
#include "map/map_tests/mwm_url_tests.cpp"
#include "map/map_tests/kmz_unarchive_test.cpp"
#include "map/map_tests/countries_names_tests.cpp"
#include "routing/routing_tests/index_graph_test.cpp"
#include "routing/routing_tests/road_penalty_test.cpp"

int main(int argc, char ** argv)
{
  try
  {
    if (argc != 3) throw std::runtime_error("expected resource ZIP and writable map directory");
    InitNaviTestPlatform(argv[1], argv[2]);
    RequireExisting(Platform::MkDirRecursively(GetPlatform().SettingsDir() + "bookmarks"),
                    "cannot prepare test bookmark directory");
    chart_generator_tests::UnitTest_GenerateChartByPoints_Test();
    chart_generator_tests::UnitTest_GenerateChart_Test();
    mwm_url_tests::UnitTest_MapApiGe0();
    mwm_url_tests::UnitTest_CrosshairApi();
    UnitTest_Multi_KML_KMZ_UnzipTest();
    UnitTest_CountriesNamesTest();
    index_graph_test::UnitTest_RestrictionTest_LoopGraph();
    road_penalty_test::UnitTest_RoadPenalty_DefaultTimes();
    road_penalty_test::UnitTest_RoadPenalty_VehicleSpecificTimes();
    std::cout << "PASS 9 existing map and routing regression cases" << std::endl;
    return 0;
  }
  catch (std::exception const & error)
  {
    std::cerr << "FAIL: " << error.what() << std::endl;
    return 1;
  }
}
