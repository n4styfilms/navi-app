#pragma once
#include <chrono>
#include <functional>
#include <string>

namespace navi::testing
{
using Pump = std::function<bool(std::function<bool()> const &, std::chrono::seconds)>;
// Same production-core scenario on Android's native test loop and desktop Qt loop.
void RunHeadlessRoutingScenario(std::string const & dataDirectory, Pump const & pump);
}
