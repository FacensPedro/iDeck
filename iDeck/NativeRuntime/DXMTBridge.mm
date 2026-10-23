#import "MadeiraRuntimeBridge.h"
#import <Metal/Metal.h>
#include <dlfcn.h>
extern "C" bool ideck_dxmt_available(void) {
    if (MTLCreateSystemDefaultDevice() == nil) return false;
    return dlsym(RTLD_DEFAULT, "madeira_get_present_count") != nullptr;
}
