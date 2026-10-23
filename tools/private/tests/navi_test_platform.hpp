#pragma once
#include "platform/platform.hpp"
#include <chrono>
#include <functional>
#include <string>

// Test OS services only. All map/routing/search/navigation code is the production core.
void InitNaviTestPlatform(std::string const & resourceApk, std::string const & writable);
bool PumpNaviTestTasks(std::function<bool()> const & done, std::chrono::seconds timeout);
