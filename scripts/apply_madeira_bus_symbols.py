#!/usr/bin/env python3
"""Name the native code behind a Wine SIGBUS/SIGSEGV.

The `BUS #N: pc=... lr=...` line of build/ntdll-unix/signal_arm64_ios.c gives raw
addresses. When the fault is in native code (Wine's Unix side, a wow64 thunk, iDeck
itself) and not in the JIT pool, nothing in the log says which function it was:
BioShock's crash read a UTF-16 string at the guest window base + 0x8002 (an atom
used as a string pointer) and the report could not say where. dladdr names the
image and the nearest exported symbol of pc and lr, logged right after that line.
"""
import sys
from pathlib import Path

MARKER = "[bus-sym]"
ANCHOR = '''            bus_pc_ok ? "" : " <unmappable PC>");
'''
ADDITION = '''        {
            /* iDeck [bus-sym]: the image and nearest symbol of pc and lr. */
            Dl_info di_pc = { 0 }, di_lr = { 0 };
            int okp = bus_pc_ok && dladdr( (void *)bus_pc_val, &di_pc );
            int okl = bus_lr_ok && dladdr( (void *)bus_lr_val, &di_lr );
            ERR( "[bus-sym] pc=%s+0x%lx (%s) lr=%s+0x%lx (%s)\\n",
                 okp && di_pc.dli_sname ? di_pc.dli_sname : "?",
                 okp ? (unsigned long)(bus_pc_val - (uintptr_t)(di_pc.dli_saddr ? di_pc.dli_saddr : di_pc.dli_fbase)) : 0ul,
                 okp && di_pc.dli_fname ? (strrchr( di_pc.dli_fname, '/' ) ? strrchr( di_pc.dli_fname, '/' ) + 1 : di_pc.dli_fname) : "not an image",
                 okl && di_lr.dli_sname ? di_lr.dli_sname : "?",
                 okl ? (unsigned long)(bus_lr_val - (uintptr_t)(di_lr.dli_saddr ? di_lr.dli_saddr : di_lr.dli_fbase)) : 0ul,
                 okl && di_lr.dli_fname ? (strrchr( di_lr.dli_fname, '/' ) ? strrchr( di_lr.dli_fname, '/' ) + 1 : di_lr.dli_fname) : "not an image" );
        }
'''


def main(madeira: Path) -> int:
    source = madeira / "build/ntdll-unix/signal_arm64_ios.c"
    text = source.read_text()
    if MARKER in text:
        return 0
    if text.count(ANCHOR) != 1 or "#include <dlfcn.h>" not in text:
        print("ERROR: signal_arm64_ios.c BUS line changed; [bus-sym] not applied", file=sys.stderr)
        return 2
    source.write_text(text.replace(ANCHOR, ANCHOR + ADDITION))
    print("Applied [bus-sym] native fault symbols")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
