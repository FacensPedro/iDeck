#include "MadeiraStaticABI.h"
#include "MadeiraRuntimeBridge.h"

extern "C" bool ideck_d3d12_available(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED && \
    defined(IDECK_MADEIRA_D3D12_ENABLED) && IDECK_MADEIRA_D3D12_ENABLED
    // The real native D3D12 canary is supplied by DXMT's static archive.
    return &madeira_d3d12_canary_run != nullptr;
#else
    return false;
#endif
}
