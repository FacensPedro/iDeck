// Madeira platform layer: which graphics paths this build can use, and the end
// of a session. Rendering, translation and presentation belong to Madeira's
// statically linked FEX, Wine, DXMT and D3D12 (MadeiraStaticABI.h).
#include "MadeiraStaticABI.h"
#import "RuntimeSupport.h"
#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// MTLCreateSystemDefaultDevice() is costly; the system device never changes
// during the process, so it is created once and shared.
static id<MTLDevice> ideck_metal_device(void) {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
}

extern "C" bool ideck_metal_available(void) {
    return ideck_metal_device() != nil;
}

extern "C" bool ideck_dxmt_available(void) {
    if (ideck_metal_device() == nil) return false;
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    // A missing DXMT renderer implementation must fail the native link.
    return &madeira_get_present_count != nullptr;
#else
    return false;
#endif
}

extern "C" bool ideck_d3d12_available(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED && \
    defined(IDECK_MADEIRA_D3D12_ENABLED) && IDECK_MADEIRA_D3D12_ENABLED
    // The real native D3D12 canary is supplied by DXMT's static archive.
    return &madeira_d3d12_canary_run != nullptr;
#else
    return false;
#endif
}

/// The end of a session: controllers are released. iDeck's caches are released
/// by ResourceGovernor (Swift), the one memory-pressure handler.
extern "C" void ideck_session_stop(void) {
    ideck_controller_stop();
}
