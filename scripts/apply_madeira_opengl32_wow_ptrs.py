#!/usr/bin/env python3
"""Make opengl32's wow64 unix thunks window-aware on iOS.

The wow64 thunks turn 32-bit guest pointers into host pointers with
ULongToPtr().  On iOS a 32-bit program's address space is a 4 GB window high
in the host address space, so that conversion must add the window base
(Borderlands 2's WPF launcher died on exactly this, in get_teb64).  Integer
values (GLintptr / GLsizeiptr casts) and GDI/GL handles are not addresses and
are left untouched.  Idempotent: a tree already converted is left alone.
"""
import re
import sys
from pathlib import Path

MARKER = "IOS_WOW_GUEST_PTR"
FILES = ("dlls/opengl32/unix_thunks.c", "dlls/opengl32/unix_wgl.c")
INT_CASTS = {"GLintptr", "GLsizeiptr", "GLintptrARB", "GLsizeiptrARB"}
# Handles and opaque guest values: never addresses the host may dereference.
NON_POINTERS = {
    "dc", "hdc", "hDC", "hDc", "hDrawDC", "hReadDC", "hPbuffer", "hShareContext",
    "hglrc", "hglrcDst", "hglrcSrc", "hrcSrvShare", "hrcSrvSource", "rc",
    "context", "newContext", "oldContext", "sync", "handle", "userParam",
    "callback", "getProcAddress", "vdpDevice", "vdpSurface", "clientBuffer",
}
CALL = re.compile(r"(\(\s*(?P<cast>[A-Za-z_]\w*)\s*\)\s*)?U[Ll]ongToPtr\(\s*(?P<arg>[^()]*?)\s*\)")
HELPER = """
#ifdef WINE_IOS
/* iDeck: 32-bit guest pointers live in the iOS WoW64 window (see
 * scripts/apply_madeira_opengl32_wow_ptrs.py). */
extern ULONG_PTR ios_wow_base(void);
static inline void *ios_wow_guest_ptr( ULONG addr )
{
    return addr ? (void *)(ios_wow_base() + (ULONG_PTR)addr) : NULL;
}
#define IOS_WOW_GUEST_PTR(a) ios_wow_guest_ptr( (ULONG)(a) )
#else
#define IOS_WOW_GUEST_PTR(a) ULongToPtr(a)
#endif
"""


def convert(text):
    count = 0

    def repl(m):
        nonlocal count
        cast, arg = m.group("cast"), m.group("arg")
        field = re.split(r"->|\.", arg)[-1].strip()
        if (cast and cast in INT_CASTS) or field in NON_POINTERS:
            return m.group(0)
        count += 1
        prefix = m.group(1) or ""
        return f"{prefix}IOS_WOW_GUEST_PTR({arg})"

    return CALL.sub(repl, text), count


def main(root):
    wine = Path(root) / "wine"
    header = wine / "dlls/opengl32/unix_private.h"
    text = header.read_text()
    if MARKER in text:
        print("opengl32 wow64 pointers already window-aware")
        return 0
    anchor = "static inline TEB *get_teb64( ULONG teb32 )"
    if anchor not in text:
        print("ERROR: opengl32 unix_private.h no longer has get_teb64", file=sys.stderr)
        return 2
    header.write_text(text.replace(anchor, HELPER.lstrip("\n") + "\n" + anchor, 1))
    total = 0
    for rel in FILES:
        path = wine / rel
        new, n = convert(path.read_text())
        path.write_text(new)
        total += n
    print(f"opengl32 wow64: {total} guest pointer conversions made window-aware")
    return 0 if total else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
