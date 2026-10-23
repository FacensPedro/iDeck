#include "MadeiraRuntimeBridge.h"
#include <dlfcn.h>
extern "C" bool ideck_d3d12_available(void) {
    return dlsym(RTLD_DEFAULT, "madeira_d3d12_canary_run") != nullptr;
}
