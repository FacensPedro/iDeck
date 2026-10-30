#import "NativeRuntimeDiagnostics.h"
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

bool ideck_native_validate_pe(const char *path) {
    if (!path || !path[0]) return false;
    FILE *file = fopen(path, "rb");
    if (!file) return false;
    unsigned char dos[64] = {};
    bool valid = fread(dos, 1, sizeof(dos), file) == sizeof(dos);
    if (valid) {
        valid = dos[0] == 'M' && dos[1] == 'Z';
    }
    if (valid) {
        uint32_t offset = (uint32_t)dos[0x3c] |
                          ((uint32_t)dos[0x3d] << 8) |
                          ((uint32_t)dos[0x3e] << 16) |
                          ((uint32_t)dos[0x3f] << 24);
        valid = offset >= 64 && offset <= 64 * 1024 * 1024;
        if (valid && fseek(file, (long)offset, SEEK_SET) == 0) {
            unsigned char pe[4] = {};
            valid = fread(pe, 1, 4, file) == 4 &&
                    pe[0] == 'P' && pe[1] == 'E' &&
                    pe[2] == 0 && pe[3] == 0;
        } else {
            valid = false;
        }
    }
    fclose(file);
    return valid;
}

bool ideck_process_has_jit_permission(void) {
    typedef int (*CodeSignStatus)(pid_t, unsigned int, void *, size_t);
    auto status = reinterpret_cast<CodeSignStatus>(dlsym(RTLD_DEFAULT, "csops"));
    uint32_t flags = 0;
    return status && status(getpid(), 0, &flags, sizeof(flags)) == 0 &&
           (flags & 0x10000000u) != 0;
}
