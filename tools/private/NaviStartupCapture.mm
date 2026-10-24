// Diagnostic simulator source, added only by prepare-ios.rb. Device builds
// compile no signal handler. A trapped app remains a failing process.
#include <TargetConditionals.h>
#if TARGET_OS_SIMULATOR || defined(NAVI_CRASH_DIAGNOSTICS_TEST)
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdint.h>
#include <sys/ucontext.h>
#include <unistd.h>

static void NaviWrite(const char *text) {
  size_t length = 0;
  while (text[length] && length < 4096) ++length;
  (void)write(STDERR_FILENO, text, length);
}
static void NaviHex(uintptr_t value) {
  char buffer[2 + sizeof(value) * 2 + 1];
  buffer[0] = '0'; buffer[1] = 'x';
  for (unsigned i = 0; i < sizeof(value) * 2; ++i)
    buffer[2 + i] = "0123456789abcdef"[(value >> ((sizeof(value) * 2 - 1 - i) * 4)) & 15];
  buffer[sizeof(buffer) - 1] = '\n';
  (void)write(STDERR_FILENO, buffer, sizeof(buffer));
}
static void NaviTrap(int number, siginfo_t *info, void *context) {
  (void)info;
  NaviWrite("NAVI_STARTUP_SIGNAL ");
  char digits[3];
  unsigned count = 0;
  if (number >= 10) digits[count++] = (char)('0' + number / 10);
  digits[count++] = (char)('0' + number % 10);
  digits[count++] = '\n';
  (void)write(STDERR_FILENO, digits, count);
  uintptr_t pc = 0;
  ucontext_t *state = (ucontext_t *)context;
#if defined(__arm64__)
  if (state && state->uc_mcontext) pc = (uintptr_t)state->uc_mcontext->__ss.__pc;
#elif defined(__x86_64__)
  if (state && state->uc_mcontext) pc = (uintptr_t)state->uc_mcontext->__ss.__rip;
#endif
  NaviWrite("NAVI_STARTUP_PC "); NaviHex(pc);
  // Record the raw PC before symbolication, which is best-effort in a signal
  // handler. The fixed raw address remains useful if unwinding cannot finish.
  Dl_info image;
  if (pc && dladdr((const void *)pc, &image)) {
    NaviWrite("NAVI_STARTUP_IMAGE "); NaviWrite(image.dli_fname); NaviWrite("\n");
    NaviWrite("NAVI_STARTUP_IMAGE_BASE "); NaviHex((uintptr_t)image.dli_fbase);
    if (image.dli_sname) { NaviWrite("NAVI_STARTUP_SYMBOL "); NaviWrite(image.dli_sname); NaviWrite("\n"); }
  }
  NaviWrite("NAVI_STARTUP_BACKTRACE\n");
  void *frames[64];
  int size = backtrace(frames, 64);
  backtrace_symbols_fd(frames, size, STDERR_FILENO);
  _exit(128 + number);
}
__attribute__((constructor)) static void NaviInstallStartupCapture(void) {
  struct sigaction action = {};
  sigemptyset(&action.sa_mask);
  action.sa_sigaction = NaviTrap;
  action.sa_flags = SA_SIGINFO | SA_RESETHAND;
  const int signals[] = {SIGTRAP, SIGABRT, SIGILL, SIGSEGV};
  for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i)
    sigaction(signals[i], &action, 0);
  NaviWrite("NAVI_STARTUP_CAPTURE_READY\n");
}
#endif
