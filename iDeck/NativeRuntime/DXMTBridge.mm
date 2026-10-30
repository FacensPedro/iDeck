#include "MadeiraStaticABI.h"
#import "MadeiraRuntimeBridge.h"
#import <Metal/Metal.h>

extern "C" bool ideck_dxmt_available(void) {
    if (MTLCreateSystemDefaultDevice() == nil) return false;
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    // A missing DXMT renderer implementation must fail the native link.
    return &madeira_get_present_count != nullptr;
#else
    return false;
#endif
}
