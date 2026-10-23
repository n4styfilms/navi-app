#include "navi_test_platform.hpp"
#include "platform/http_client.hpp"
#include "platform/locale.hpp"
#include "platform/network_policy.hpp"
#include <condition_variable>
#include <deque>
#include <mutex>
#include <stdexcept>

namespace
{
class TestTaskLoop final : public base::TaskLoop
{
public:
  PushResult Push(Task && task) override
  {
    std::lock_guard lock(m_mutex);
    m_tasks.push_back(std::move(task));
    m_ready.notify_one();
    return {true, kNoId};
  }
  PushResult Push(Task const & task) override { return Push(Task(task)); }
  bool Pump(std::function<bool()> const & done, std::chrono::seconds timeout)
  {
    auto const deadline = std::chrono::steady_clock::now() + timeout;
    while (!done())
    {
      Task task;
      {
        std::unique_lock lock(m_mutex);
        if (!m_ready.wait_until(lock, deadline, [this] { return !m_tasks.empty(); }))
          return done();
        task = std::move(m_tasks.front());
        m_tasks.pop_front();
      }
      task();
      if (std::chrono::steady_clock::now() >= deadline)
        return done();
    }
    return true;
  }
private:
  std::mutex m_mutex;
  std::condition_variable m_ready;
  std::deque<Task> m_tasks;
};
TestTaskLoop * g_loop = nullptr;
class TestPlatform final : public Platform
{
public:
  void Init(std::string const & apk, std::string const & writable)
  {
    m_resourcesDir = apk; // Android GetReader expects an APK zip, without a trailing slash.
    SetWritableDirForTests(writable);
    SetSettingsDir(writable);
    m_tmpDir = m_writableDir;
    auto loop = std::make_unique<TestTaskLoop>();
    g_loop = loop.get();
    SetGuiThread(std::move(loop));
  }
};
TestPlatform g_platform;
}
Platform & GetPlatform() { return g_platform; }
void InitNaviTestPlatform(std::string const & apk, std::string const & writable)
{ g_platform.Init(apk, writable); }
bool PumpNaviTestTasks(std::function<bool()> const & done, std::chrono::seconds timeout)
{ return g_loop->Pump(done, timeout); }

std::string Platform::DeviceName() const { return "Navi headless regression"; }
std::string Platform::DeviceModel() const { return "Android emulator"; }
std::string Platform::Version() const { return "test"; }
int32_t Platform::IntVersion() const { return 1; }
std::string Platform::GetMemoryInfo() const { return {}; }
Platform::EConnectionType Platform::ConnectionStatus() { return EConnectionType::CONNECTION_NONE; }
Platform::ChargingStatus Platform::GetChargingStatus() { return ChargingStatus::Plugged; }
uint8_t Platform::GetBatteryLevel() { return 100; }
std::vector<std::string> GetAndroidSystemLanguages() { return {"en"}; }
namespace platform
{
Locale GetCurrentLocale() { return {"en", "GB", "GBP", ".", ","}; }
bool GetLocale(std::string, Locale & result) { result = GetCurrentLocale(); return true; }
NetworkPolicy GetCurrentNetworkPolicy() { return NetworkPolicy(false); }
bool HttpClient::RunHttpRequest() { return false; } // Explicit offline OS environment.
}

// This executable has no JVM and no JNI callers. Worker threads remain real native threads.
void AndroidThreadAttachToJVM() {}
void AndroidThreadDetachFromJVM() {}
class HttpThread;
namespace downloader
{
class IHttpThreadCallback;
HttpThread * CreateNativeHttpThread(std::string const &, IHttpThreadCallback &, int64_t, int64_t,
                                    int64_t, std::string const &)
{
  throw std::runtime_error("Unexpected asynchronous network request in offline routing test");
}
void DeleteNativeHttpThread(HttpThread *)
{
  throw std::runtime_error("Unexpected network thread in offline routing test");
}
}
