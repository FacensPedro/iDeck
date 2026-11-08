#!/usr/bin/env python3
"""Stop rewriting ~1,450 DLL symlinks in the Wine prefix on every launch.

WineProcessBridge.m removes and recreates every system32/sysx64/sysaa64/
syswow64/winsxs/Mono link at each session start "because the bundle path
changes on reinstall".  That only happens on reinstall.  Each
`[fm removeItemAtPath:X ...]` that is followed (within a few lines) by
`[fm createSymbolicLinkAtPath:X withDestinationPath:S ...]` becomes
`madeira_relink(fm, X, S)`: readlink(2) first, and only an absent, real-file
or differently-targeted entry is replaced.  The resulting prefix is identical
to the old behaviour; only the unchanged links are no longer rewritten.
Idempotent.
"""
import re
import sys
from pathlib import Path

MARKER = "madeira_relink("
HELPER = r'''
/* iDeck: replace a prefix symlink only when it does not already point at
 * `src` (scripts/apply_madeira_relink_cache.py).  Same result as the old
 * remove + create, without rewriting the unchanged links every launch. */
static BOOL madeira_relink(NSFileManager *fm, NSString *dst, NSString *src)
{
    char cur[4096];
    ssize_t n = readlink(dst.fileSystemRepresentation, cur, sizeof(cur) - 1);
    if (n > 0) {
        cur[n] = 0;
        if (!strcmp(cur, src.fileSystemRepresentation)) return YES;
    }
    [fm removeItemAtPath:dst error:nil];
    return [fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil];
}
'''
CREATE = re.compile(r"\[fm createSymbolicLinkAtPath:(\w+)\s+withDestinationPath:(\w+|\[[^\[\]]*\])\s+error:nil\]")


def convert(text):
    out, pos, converted = [], 0, 0
    for m in CREATE.finditer(text):
        var, src = m.group(1), m.group(2)
        window_start = max(pos, text.rfind("\n", 0, max(0, m.start() - 400)))
        window = text[window_start:m.start()]
        rm = None
        for rm in re.finditer(r"\[fm removeItemAtPath:%s error:nil\];[^\n]*" % re.escape(var), window):
            pass
        if not rm or window[rm.end():].count("\n") > 3:
            continue
        a, b = window_start + rm.start(), window_start + rm.end()
        out.append(text[pos:a])
        out.append("/* replaced only when stale: madeira_relink */")
        out.append(text[b:m.start()])
        out.append(f"madeira_relink(fm, {var}, {src})")
        pos = m.end()
        converted += 1
    out.append(text[pos:])
    return "".join(out), converted


def main(root):
    path = Path(root) / "app/Madeira/WineProcessBridge.m"
    text = path.read_text()
    if MARKER in text:
        print("prefix links already cached")
        return 0
    # The helper goes before the first function definition that uses links.
    anchor = re.search(r"^static [^\n]*\(NSFileManager \*fm", text, re.M)
    if not anchor:
        print("ERROR: no link helper anchor in WineProcessBridge.m", file=sys.stderr)
        return 2
    head, tail = text[:anchor.start()], text[anchor.start():]
    tail, n = convert(tail)
    if n < 8:
        print(f"ERROR: only {n} link sites matched; WineProcessBridge.m changed", file=sys.stderr)
        return 2
    path.write_text(head + HELPER.lstrip("\n") + "\n" + tail)
    print(f"prefix links: {n} remove+create sites now replace only stale links")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
