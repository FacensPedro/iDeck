#ifndef IDECK_NATIVE_RUNTIME_DIAGNOSTICS_H
#define IDECK_NATIVE_RUNTIME_DIAGNOSTICS_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    bool metal_available;
    bool metal_family_apple7_or_newer;
    bool fex_linked;
    bool wine_linked;
    bool dxmt_linked;
    bool d3d12_linked;
    bool launcher_linked;
    uint64_t recommended_max_buffer_length;
} IDeckNativeCapabilities;
IDeckNativeCapabilities ideck_native_capabilities(void);
bool ideck_process_has_jit_permission(void);
// Returns 0x014c for x86 PE32, 0x8664 for AMD64 PE32+, or 0 if invalid.
uint16_t ideck_native_pe_machine(const char *path);
bool ideck_native_validate_pe(const char *path);
#ifdef __cplusplus
}
#endif
#endif
