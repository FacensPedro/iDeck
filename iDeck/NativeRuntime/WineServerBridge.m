#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
bool ideck_wineserver_available(void) {
    return dlsym(RTLD_DEFAULT, "wineserver_start") != NULL &&
           dlsym(RTLD_DEFAULT, "wineserver_is_ready") != NULL;
}
bool ideck_wineserver_ready(void) {
    typedef int (*ReadyFn)(void);
    ReadyFn ready = (ReadyFn)dlsym(RTLD_DEFAULT, "wineserver_is_ready");
    return ready && ready() != 0;
}
bool ideck_wineserver_initialize(void) {
    const char *prefix = getenv("WINEPREFIX");
    if (!prefix || !*prefix) return false;
    @synchronized ([NSProcessInfo processInfo]) {
        if (ideck_wineserver_ready()) return true;
        typedef int (*StartFn)(const char *);
        StartFn start = (StartFn)dlsym(RTLD_DEFAULT, "wineserver_start");
        if (!start || start(prefix) != 0) return false;
        for (int i = 0; i < 300; ++i) {
            if (ideck_wineserver_ready()) return true;
            usleep(10000);
        }
        return false;
    }
}
