#import "MadeiraRuntimeBridge.h"
#include <dlfcn.h>
#include <cstring>
#include <cerrno>
extern "C" bool ideck_wineprocess_available(void) {
    return dlsym(RTLD_DEFAULT, "wine_process_start") != nullptr &&
           dlsym(RTLD_DEFAULT, "wine_process_is_running") != nullptr;
}
extern "C" bool ideck_wineprocess_running(void) {
    using Running = bool (*)(void);
    auto running = reinterpret_cast<Running>(dlsym(RTLD_DEFAULT, "wine_process_is_running"));
    return running && running();
}
extern "C" int32_t ideck_wineprocess_start(const char *executable_path) {
    if (!executable_path || !*executable_path) return EINVAL;
    using Start = void (*)(const char *);
    auto start = reinterpret_cast<Start>(dlsym(RTLD_DEFAULT, "wine_process_start"));
    if (!start) return ENOSYS;
    start(executable_path);
    return ideck_wineprocess_running() ? 0 : EAGAIN;
}
