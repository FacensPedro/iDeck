#!/usr/bin/env python3
"""Read Wine's Windows files from the downloaded runtime, not only the app bundle.

iDeck's IPA no longer carries the PE farms (aarch64-windows, arm64ec-windows,
i386-windows, nls, compat, vulkan): the initial setup downloads them into
Library/Application Support/MadeiraRuntime (MadeiraRuntime.swift).  Every
`[[NSBundle mainBundle] bundlePath]` in WineProcessBridge.m and WineServerBridge.m
that names the Windows files becomes `madeira_runtime_root()`, which answers
that folder once it holds arm64ec-windows/ntdll.dll and the bundle otherwise
(development builds that still stage the farms).  The iOS dylibs (gl/) and the
prefix template stay in the signed bundle.  Idempotent.
"""
import re
import sys
from pathlib import Path

MARKER = "madeira_runtime_root("
HELPER = r'''
/* iDeck: Wine's Windows files, downloaded by the initial setup into
 * Library/Application Support/MadeiraRuntime, else the app bundle
 * (scripts/apply_madeira_runtime_root.py). */
static NSString *madeira_runtime_root(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (support) {
        NSString *root = [support stringByAppendingPathComponent:@"MadeiraRuntime"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"arm64ec-windows/ntdll.dll"]])
            return root;
    }
    return [[NSBundle mainBundle] bundlePath];
}
'''
GL = '[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"gl"]'
GL_HOLD = "@@IDECK_GL_BUNDLE@@"
PATTERNS = ("[[NSBundle mainBundle] bundlePath]", "NSBundle.mainBundle.bundlePath")


def convert(path: Path, minimum: int) -> int:
    text = path.read_text()
    if MARKER in text:
        print(f"{path.name}: runtime root already applied")
        return 0
    text = text.replace(GL, GL_HOLD)
    count = 0
    for pattern in PATTERNS:
        count += text.count(pattern)
        text = text.replace(pattern, "madeira_runtime_root()")
    text = text.replace(GL_HOLD, GL)
    if count < minimum:
        print(f"ERROR: {path.name}: only {count} bundle paths matched; source changed", file=sys.stderr)
        return 2
    first_use = text.index("madeira_runtime_root()")
    imports = [m for m in re.finditer(r"^#(?:import|include)[^\n]*\n", text, re.M) if m.end() <= first_use]
    if not imports:
        print(f"ERROR: {path.name}: no #import anchor", file=sys.stderr)
        return 2
    at = imports[-1].end()
    path.write_text(text[:at] + HELPER + text[at:])
    print(f"{path.name}: {count} Windows-file paths read the downloaded runtime")
    return 0


def main(root: str) -> int:
    base = Path(root) / "app/Madeira"
    for name, minimum in (("WineProcessBridge.m", 3), ("WineServerBridge.m", 1)):
        status = convert(base / name, minimum)
        if status:
            return status
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
