#import "MadeiraRuntimeBridge.h"
#include <dlfcn.h>
#include <cstdlib>
#include <cerrno>
extern "C" bool ideck_wineprocess_available(void) {
    return dlsym(RTLD_DEFAULT, "wine_process_start") != nullptr &&
           dlsym(RTLD_DEFAULT, "wine_process_is_running") != nullptr;
}
extern "C" bool ideck_wineprocess_running(void) {
    using Running = int (*)(void);
    auto running = reinterpret_cast<Running>(dlsym(RTLD_DEFAULT, "wine_process_is_running"));
    return running && running() != 0;
}
extern "C" int32_t ideck_wineprocess_start(const char *executable_path) {
    if (!executable_path || !*executable_path) return EINVAL;
    const char *prefix = getenv("WINEPREFIX");
    if (!prefix || !*prefix) return EINVAL;
    using Start = int (*)(const char *);
    auto start = reinterpret_cast<Start>(dlsym(RTLD_DEFAULT, "wine_process_start"));
    if (!start) return ENOSYS;
    return start(prefix) == 0 ? 0 : EIO;
}
