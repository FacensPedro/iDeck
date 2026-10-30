#import "NativeRuntimeDiagnostics.h"
#include "NativeRuntime/WindowsPEMachine.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

static bool ideck_symbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name) != NULL;
}

IDeckNativeCapabilities ideck_native_capabilities(void) {
    IDeckNativeCapabilities capabilities = {};
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        capabilities.metal_available = device != nil;
        if (device) {
            if (@available(iOS 16.0, *)) {
                capabilities.metal_family_apple7_or_newer =
                    [device supportsFamily:MTLGPUFamilyApple7];
            }
            capabilities.recommended_max_buffer_length = device.maxBufferLength;
        }
    }
    capabilities.fex_linked = ideck_symbol("fex_initialize");
    capabilities.wine_linked = ideck_symbol("wineserver_start") &&
                               ideck_symbol("wine_process_start");
    capabilities.dxmt_linked = ideck_symbol("madeira_get_present_count");
#if defined(IDECK_MADEIRA_D3D12_ENABLED) && IDECK_MADEIRA_D3D12_ENABLED
    capabilities.d3d12_linked = ideck_symbol("madeira_d3d12_canary_run");
#else
    capabilities.d3d12_linked = false;
#endif
    capabilities.launcher_linked = ideck_symbol("ideck_madeira_launch_v1");
    return capabilities;
}

uint16_t ideck_native_pe_machine(const char *path) {
    return ideck_pe_machine_from_file(path);
}

bool ideck_native_validate_pe(const char *path) {
    return ideck_native_pe_machine(path) != 0;
}

bool ideck_process_has_jit_permission(void) {
    typedef int (*CodeSignStatus)(pid_t, unsigned int, void *, size_t);
    auto status = reinterpret_cast<CodeSignStatus>(dlsym(RTLD_DEFAULT, "csops"));
    uint32_t flags = 0;
    return status && status(getpid(), 0, &flags, sizeof(flags)) == 0 &&
           (flags & 0x10000000u) != 0;
}
