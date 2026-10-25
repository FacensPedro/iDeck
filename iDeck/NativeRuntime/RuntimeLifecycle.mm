#import "RuntimeSupport.h"
#import "NativePerformance.h"
#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#include <atomic>
#include <cerrno>
static std::atomic<int32_t> session_state{IDECK_SESSION_STOPPED};
extern "C" int32_t ideck_session_prepare(const char *prefix) {
    int32_t expected = IDECK_SESSION_STOPPED;
    if (!session_state.compare_exchange_strong(expected, IDECK_SESSION_PREPARING)) return EBUSY;
    int32_t result = ideck_wine_environment_configure(prefix);
    if (!result) result = ideck_runtime_prepare(prefix);
    if (result) {
        ideck_runtime_report_error(result, "Runtime initialization failed");
        session_state.store(IDECK_SESSION_FAILED);
    } else {
        session_state.store(IDECK_SESSION_READY);
    }
    return result;
}
extern "C" void ideck_session_stop(void) {
    ideck_controller_stop();
    session_state.store(IDECK_SESSION_STOPPED);
}
extern "C" int32_t ideck_session_state(void) { return session_state.load(); }
