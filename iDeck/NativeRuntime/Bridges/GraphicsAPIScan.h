#ifndef IDECK_GRAPHICS_API_SCAN_H
#define IDECK_GRAPHICS_API_SCAN_H

/* Which graphics APIs a Windows program can use, read from its PE file:
 * the import and delay-import tables (static use) and DLL names stored as
 * ASCII or UTF-16 text in the first and last 4 MB (LoadLibrary at run time).
 * A program may use several; Wine loads each API's DLL only when called. */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    IDECK_API_D3D9 = 1u << 0,
    IDECK_API_D3D10 = 1u << 1,
    IDECK_API_D3D11 = 1u << 2,
    IDECK_API_D3D12 = 1u << 3,
    IDECK_API_DXGI = 1u << 4,
    IDECK_API_VULKAN = 1u << 5,
    IDECK_API_OPENGL = 1u << 6,
    /* Set when the API came from the import tables, not only from text. */
    IDECK_API_STATIC_SHIFT = 16
};

/* Bits of the APIs referenced by the file at `path`; 0 when none or unreadable.
 * Statically imported APIs are also reported shifted by IDECK_API_STATIC_SHIFT. */
uint32_t ideck_pe_graphics_apis(const char *path);

#ifdef __cplusplus
}
#endif

#endif
