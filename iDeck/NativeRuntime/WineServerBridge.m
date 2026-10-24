#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <errno.h>

bool ideck_wineserver_available(void) {
    return dlsym(RTLD_DEFAULT, "wineserver_start") != NULL &&
           dlsym(RTLD_DEFAULT, "wineserver_is_ready") != NULL;
}

bool ideck_wineserver_ready(void) {
    typedef int (*ReadyFn)(void);
    ReadyFn ready = (ReadyFn)dlsym(RTLD_DEFAULT, "wineserver_is_ready");
    return ready != NULL && ready() != 0;
}

bool ideck_wineserver_initialize(const char *wine_prefix) {
    if (wine_prefix == NULL || wine_prefix[0] == '\0') return false;
    @synchronized ([NSProcessInfo processInfo]) {
        if (ideck_wineserver_ready()) return true;
        typedef int (*StartFn)(const char *);
        StartFn start = (StartFn)dlsym(RTLD_DEFAULT, "wineserver_start");
        if (start == NULL || start(wine_prefix) != 0) return false;
        for (unsigned int attempt = 0; attempt < 200; ++attempt) {
            if (ideck_wineserver_ready()) return true;
            usleep(25000);
        }
        return false;
    }
}
