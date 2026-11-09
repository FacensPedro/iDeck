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


DATA_MARKER = "MADEIRA_DATA_DIR"
DATA_ENV = '''            setenv("WINEDLLPATH", bundlePath.UTF8String, 1);
            /* iDeck: Wine's data files (nls/) are in the downloaded runtime too. */
            setenv("MADEIRA_DATA_DIR", bundlePath.UTF8String, 1);
'''
DATA_LOADER = '''    set_dll_path();
    /* iDeck: Wine's data files (nls/) come from the runtime the initial setup
     * downloads, not from the app bundle (scripts/apply_madeira_runtime_root.py). */
    {
        const char *runtime_data = getenv( "MADEIRA_DATA_DIR" );
        if (runtime_data && runtime_data[0] == '/') data_dir = strdup( runtime_data );
    }
'''


def data_dir(root: Path) -> int:
    """ntdll reads nls/ from data_dir, derived from the app executable's folder."""
    bridge = root / "app/Madeira/WineProcessBridge.m"
    text = bridge.read_text()
    if DATA_MARKER not in text:
        anchor = '            setenv("WINEDLLPATH", bundlePath.UTF8String, 1);\n'
        if text.count(anchor) != 1:
            print("ERROR: WineProcessBridge.m: no WINEDLLPATH anchor", file=sys.stderr)
            return 2
        bridge.write_text(text.replace(anchor, DATA_ENV))
        print("WineProcessBridge.m: MADEIRA_DATA_DIR names the runtime for ntdll")
    loader = root / "wine/dlls/ntdll/unix/loader.c"
    text = loader.read_text()
    if DATA_MARKER not in text:
        anchor = "    set_dll_path();\n"
        if text.count(anchor) != 1:
            print("ERROR: ntdll loader.c: no set_dll_path anchor", file=sys.stderr)
            return 2
        loader.write_text(text.replace(anchor, DATA_LOADER))
        print("ntdll loader.c: data_dir follows MADEIRA_DATA_DIR")
    return 0


def main(root: str) -> int:
    base = Path(root) / "app/Madeira"
    for name, minimum in (("WineProcessBridge.m", 3), ("WineServerBridge.m", 1)):
        status = convert(base / name, minimum)
        if status:
            return status
    return data_dir(Path(root))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
