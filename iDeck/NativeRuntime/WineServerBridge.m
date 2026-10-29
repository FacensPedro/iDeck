#include "MadeiraStaticABI.h"
#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <errno.h>

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
        // Wine generally initializes its registry in tens of milliseconds.
        // Poll rapidly for the first 250 ms instead of waiting a whole 25 ms
        // for each check, then back off without shortening the 5 s cap.
        for (unsigned int attempt = 0; attempt < 50; ++attempt) {
            if (ideck_wineserver_ready()) return true;
            usleep(5000);
        }
        for (unsigned int attempt = 0; attempt < 190; ++attempt) {
            if (ideck_wineserver_ready()) return true;
            usleep(25000);
        }
        return false;
    }
}
