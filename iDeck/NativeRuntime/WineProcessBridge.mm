#include "MadeiraStaticABI.h"
#import "MadeiraRuntimeBridge.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <cerrno>
#include <climits>

extern "C" bool ideck_wineprocess_available(void) {
    return dlsym(RTLD_DEFAULT, "wine_process_start") != nullptr &&
           dlsym(RTLD_DEFAULT, "wine_process_is_running") != nullptr;
}

extern "C" bool ideck_wineprocess_running(void) {
    using Running = int (*)(void);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    Running running = &wine_process_is_running;
#else
    auto running = reinterpret_cast<Running>(dlsym(RTLD_DEFAULT, "wine_process_is_running"));
#endif
    return running != nullptr && running() != 0;
}

extern "C" bool ideck_wineprocess_thread_finished(void) {
    using Finished = int (*)(void);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    Finished finished = &wine_process_thread_finished;
#else
    auto finished = reinterpret_cast<Finished>(dlsym(RTLD_DEFAULT, "wine_process_thread_finished"));
#endif
    // An interface-only IPA has no Wine guest thread at all. It should still
    // be able to close the error screen, but a native Wine build lacking the
    // completion marker must never be treated as safe to restart.
    if (finished) return finished() != 0;
    return !ideck_wineprocess_available();
}

extern "C" int32_t ideck_wineprocess_start(const char *wine_prefix) {
    if (wine_prefix == nullptr || wine_prefix[0] == '\0') return EINVAL;
    using Start = int (*)(const char *);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    Start start = &wine_process_start;
#else
    auto start = reinterpret_cast<Start>(dlsym(RTLD_DEFAULT, "wine_process_start"));
#endif
    if (start == nullptr) return ENOSYS;
    int result = start(wine_prefix);
    if (result != 0) return EIO;
    return ideck_wineprocess_running() ? 0 : EAGAIN;
}

extern "C" bool ideck_wineprocess_last_exit_code(int32_t *code) {
    using ExitCode = int (*)(void);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    ExitCode read = &wine_process_exit_code;
#else
    auto read = reinterpret_cast<ExitCode>(dlsym(RTLD_DEFAULT, "wine_process_exit_code"));
#endif
    if (!read || !code) return false;
    *code = read();
    return true;
}

extern "C" bool ideck_wineprocess_last_ntstatus(uint32_t *code) {
    using CrashStatus = int (*)(uint32_t *);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    CrashStatus read = &wine_crash_exit_status;
#else
    auto read = reinterpret_cast<CrashStatus>(dlsym(RTLD_DEFAULT, "wine_crash_exit_status"));
#endif
    return code && read && read(code) != 0;
}

extern "C" bool ideck_wineprocess_request_close(void) {
    using PostKey = void (*)(unsigned int, int);
    if (!ideck_wineprocess_running()) return false;
    auto post = reinterpret_cast<PostKey>(dlsym(RTLD_DEFAULT, "winios_post_key"));
    if (post == nullptr) return false;
    post(0x12, 1);
    post(0x73, 1);
    // Do not block the UI; key-up is emitted shortly afterwards.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        post(0x73, 0);
        post(0x12, 0);
    });
    return true;
}
