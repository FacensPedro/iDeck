#ifndef IDECK_NATIVE_RUNTIME_ABI_H
#define IDECK_NATIVE_RUNTIME_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ABI 1: implemented by a real, statically linked Madeira-derived native
 * runtime, not by the Swift UI. Must execute the guest inside the iDeck
 * process and return once the guest session is initialized.
 *
 * executable_path: absolute path to a Windows PE executable within the app
 *                   sandbox (or a previously security-scoped copy).
 * wine_prefix:     absolute path to the writable Wine prefix.
 * request_json:    UTF-8 object containing:
 *                   {"version":1,"arguments":[...],
 *                    "is32Bit":false,"isSteam":false}
 *
 * Returns 0 once the guest session starts, nonzero on startup failure.\n * Process exit and rendering updates must be delivered through the\n * separately integrated Wine runtime/session callbacks.
 * Implementation must initialize FEX, wineserver and Wine in the correct
 * upstream order and install the DXMT/Direct3D 12 components. It must not
 * use posix_spawn/exec to launch unsigned native binaries on iOS.
 *
 * This declaration provides an ABI contract only. It does NOT implement
 * FEX, Wine, DXMT or D3D12, and does not cause runtime readiness by itself.
 */
int32_t ideck_madeira_launch_v1(const char *executable_path,
                               const char *wine_prefix,
                               const char *request_json);

#ifdef __cplusplus
}
#endif

#endif
