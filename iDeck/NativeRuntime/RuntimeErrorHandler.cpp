#include "RuntimeSupport.h"
#include <atomic>
#include <cstdio>
#include <mutex>
static std::atomic<int32_t> last_error{0};
static std::mutex error_mutex;
extern "C" void ideck_runtime_report_error(int32_t code, const char *message) {
    last_error.store(code);
    std::lock_guard<std::mutex> lock(error_mutex);
    std::fprintf(stderr, "iDeck native runtime error %d: %s\n", code, message ? message : "unspecified");
}
extern "C" int32_t ideck_runtime_last_error(void) { return last_error.load(); }
