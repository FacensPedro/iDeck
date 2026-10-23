#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
bool ideck_wineserver_available(void) {
    return dlsym(RTLD_DEFAULT, "wineserver_start") != NULL &&
           dlsym(RTLD_DEFAULT, "wineserver_is_ready") != NULL;
}
bool ideck_wineserver_ready(void) {
    typedef bool (*ReadyFn)(void);
    ReadyFn ready = (ReadyFn)dlsym(RTLD_DEFAULT, "wineserver_is_ready");
    return ready && ready();
}
bool ideck_wineserver_initialize(void) {
    @synchronized ([NSProcessInfo processInfo]) {
        if (ideck_wineserver_ready()) return true;
        typedef void (*StartFn)(void);
        StartFn start = (StartFn)dlsym(RTLD_DEFAULT, "wineserver_start");
        if (!start) return false;
        start();
        return ideck_wineserver_ready();
    }
}
