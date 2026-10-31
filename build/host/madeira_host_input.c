/* iDeck host implementation of a Madeira switch that upstream resolves in
 * Swift (HardwareInput.swift, @_cdecl("winios_mouse_routing_enabled")).
 *
 * Winios.m and build/win32u-unix/driver_ios.c call this to decide whether a
 * connected mouse is routed to the guest. Upstream semantics are kept:
 * default on; only `env.MADEIRA_MOUSE_ROUTING = 0` in madeira.cfg (or the
 * MADEIRA_MOUSE_ROUTING environment variable) turns it off. The answer is
 * read once and cached, like the Swift static it replaces. */
#include <stdlib.h>
#include <string.h>
#include "madeira_cfg.h"

int winios_mouse_routing_enabled(void)
{
    static int cached = -1;
    if (cached < 0) {
        char value[16] = "";
        int on = 1;
        if (madeira_cfg_get("env.MADEIRA_MOUSE_ROUTING", value, sizeof value)) {
            on = strcmp(value, "0") != 0;
        } else {
            const char *env = getenv("MADEIRA_MOUSE_ROUTING");
            if (env) on = strcmp(env, "0") != 0;
        }
        cached = on;
    }
    return cached;
}
