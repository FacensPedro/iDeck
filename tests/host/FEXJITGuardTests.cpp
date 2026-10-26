#include <cassert>
#include <cstdio>
#include "../../iDeck/NativeRuntime/MadeiraRuntimeBridge.h"

// CI runs this host test outside of an attached debugger. FEX must reject the
// attempt instead of reaching jit26_prepare_region's process-fatal BRK #0xf00d.
int main() {
    assert(!ideck_fex_jit_ready());
    assert(!ideck_fex_initialize());
    assert(!ideck_fex_jit_ready());
    std::puts("PASS: FEX refuses unhandled JIT debugger traps");
    return 0;
}
