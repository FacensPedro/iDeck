#import "RuntimeSupport.h"
#import "NativePerformance.h"
#import "NativeMemoryManager.h"
#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#include <atomic>
#include <cerrno>
static std::atomic<int32_t> session_state{IDECK_SESSION_STOPPED};
extern "C" void ideck_session_stop(void) {
    ideck_controller_stop();
    ideck_native_memory_trim();
    session_state.store(IDECK_SESSION_STOPPED);
}
extern "C" int32_t ideck_session_state(void) { return session_state.load(); }
