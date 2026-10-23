// Run the same core capture cases locally without the Qt event-loop test runner.
// Route, geometry, measurement and capture implementations are the production code.
#include "testing/testing.hpp"
#include "platform/measurement_utils.hpp"
#include <iostream>
#include <stdexcept>

namespace
{
void RequireCapture(bool value, char const * expression)
{
  if (!value)
    throw std::runtime_error(expression);
}

bool AssertCapture(base::SrcPoint const &, std::string const & message)
{
  throw std::runtime_error(message);
}
}

// Diagnostic sink only: a production CHECK failure fails the test immediately.
namespace base { AssertFailedFn OnAssertFailed = AssertCapture; }

// This adapter must never depend on localized/rounded display values. Fail if
// one of those external platform services is reached instead of the numeric API.
namespace measurement_utils
{
Units GetMeasurementUnits() { throw std::runtime_error("capture consulted display units"); }
std::string ToStringPrecision(double, int) { throw std::runtime_error("capture rounded display data"); }
}
namespace platform
{
std::string GetLocalizedString(std::string const &) { throw std::runtime_error("capture consulted localization"); }
}

#undef UNIT_TEST
#undef TEST
#undef TEST_EQUAL
#undef TEST_LESS
#undef TEST_GREATER
#define UNIT_TEST(name) void UnitTest_##name()
#define TEST(value, message) RequireCapture(static_cast<bool>(value), #value)
#define TEST_EQUAL(left, right, message) RequireCapture((left) == (right), #left " == " #right)
#define TEST_LESS(left, right, message) RequireCapture((left) < (right), #left " < " #right)
#define TEST_GREATER(left, right, message) RequireCapture((left) > (right), #left " > " #right)
#include "map/map_tests/navi_route_snapshot_tests.cpp"

int main()
{
  try
  {
    UnitTest_NaviSnapshot_CapturesRealUnroundedRouteMetrics();
    UnitTest_NaviSnapshot_CoordinateOrderAndSpeedUnits();
    UnitTest_NaviSnapshot_InvalidRouteHasNoCostInput();
    UnitTest_NaviSnapshot_WarningsUseMetersAndStopAtBoundary();
    UnitTest_NaviSnapshot_CopiesRoadWarningsWithoutRenderer();
    UnitTest_NaviSnapshot_RejectsInvalidCoreMetrics();
    std::cout << "PASS 6 real route capture cases\n";
    return 0;
  }
  catch (std::exception const & error)
  {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
