#include "MadeiraRuntimeBridge.h"
#include <dlfcn.h>
#include <mutex>
namespace {
std::mutex fex_mutex;
bool fex_initialized = false;
}
extern "C" bool ideck_fex_available(void) {
    return dlsym(RTLD_DEFAULT, "fex_initialize") != nullptr;
}
extern "C" bool ideck_fex_initialize(void) {
    std::lock_guard<std::mutex> lock(fex_mutex);
    if (fex_initialized) return true;
    using Init = bool (*)(void);
    auto init = reinterpret_cast<Init>(dlsym(RTLD_DEFAULT, "fex_initialize"));
    if (!init) return false;
    fex_initialized = init();
    return fex_initialized;
}
