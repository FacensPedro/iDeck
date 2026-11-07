// Wine guest process and wineserver control (statically linked Madeira ABI,
// dlsym fallback in interface-only builds).
#include "MadeiraStaticABI.h"
#import "MadeiraRuntimeBridge.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <cerrno>
#include <climits>
#include <unistd.h>

extern "C" bool ideck_wineprocess_available(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    return &wine_process_start != nullptr && &wine_process_is_running != nullptr;
#else
    return false;
#endif
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
    // As Madeira's startWineProcess: wine_process_start returning 0 means the
    // Wine thread was launched; its state is followed afterwards, not judged
    // within the first half second.
    return start(wine_prefix) == 0 ? 0 : EIO;
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
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    if (!ideck_wineprocess_running()) return false;
    // Use the pinned Winios ABI. A missing key bridge is a link failure.
    void (*post)(int, int) = &winios_post_key;
    post(0x12, 1);
    post(0x73, 1);
    // Do not block the UI; key-up is emitted shortly afterwards.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        post(0x73, 0);
        post(0x12, 0);
    });
    return true;
#else
    return false;
#endif
}

// MARK: - wineserver

#import <Foundation/Foundation.h>

bool ideck_wineserver_available(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    return &wineserver_start != NULL && &wineserver_is_ready != NULL;
#else
    return false;
#endif
}

bool ideck_wineserver_running(void) {
    typedef int (*RunningFn)(void);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    RunningFn running = &wineserver_is_running;
#else
    RunningFn running = (RunningFn)dlsym(RTLD_DEFAULT, "wineserver_is_running");
#endif
    return running != NULL && running() != 0;
}

bool ideck_wineserver_ready(void) {
    typedef int (*ReadyFn)(void);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    ReadyFn ready = &wineserver_is_ready;
#else
    ReadyFn ready = (ReadyFn)dlsym(RTLD_DEFAULT, "wineserver_is_ready");
#endif
    return ready != NULL && ready() != 0;
}

bool ideck_wineserver_initialize(const char *wine_prefix) {
    if (wine_prefix == NULL || wine_prefix[0] == '\0') return false;
    @synchronized ([NSProcessInfo processInfo]) {
        if (ideck_wineserver_ready()) return true;
        typedef int (*StartFn)(const char *);
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
        StartFn start = &wineserver_start;
#else
        StartFn start = (StartFn)dlsym(RTLD_DEFAULT, "wineserver_start");
#endif
        if (start == NULL || start(wine_prefix) != 0) return false;
        // As Madeira's launch (MADEIRA_FAST_SERVER_START): Wine starts as soon
        // as the wineserver is ready, waiting at most 2 s, and then starts
        // anyway while the server is still running.
        for (unsigned int attempt = 0; attempt < 200; ++attempt) {
            if (ideck_wineserver_ready() || !ideck_wineserver_running()) break;
            usleep(10000);
        }
        return ideck_wineserver_running();
    }
}

// The native Wine startup initializes its wineserver BEFORE spawning the
// Windows guest. A failed socketpair/pthread_create can leave an orphaned
// wineserver even though the Wine guest never began. Only that idle server
// may be stopped from iDeck; an active guest owns its own shutdown path.
static BOOL g_ideck_idle_server_stop_pending = NO;

bool ideck_wineserver_stop_if_idle(void) {
    if (ideck_wineprocess_running() || !ideck_wineprocess_thread_finished() ||
        !ideck_wineserver_running()) return false;

    @synchronized ([NSProcessInfo processInfo]) {
        if (g_ideck_idle_server_stop_pending) return true;
        g_ideck_idle_server_stop_pending = YES;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!ideck_wineprocess_running() && ideck_wineprocess_thread_finished() &&
            ideck_wineserver_running()) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
            wineserver_stop();
#else
            typedef void (*StopFn)(void);
            StopFn stop = (StopFn)dlsym(RTLD_DEFAULT, "wineserver_stop");
            if (stop != NULL) stop();
#endif
        }
        @synchronized ([NSProcessInfo processInfo]) {
            g_ideck_idle_server_stop_pending = NO;
        }
    });
    return true;
}
