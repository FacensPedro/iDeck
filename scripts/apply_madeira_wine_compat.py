#!/usr/bin/env python3
"""Apply the vendored Wine Staging and GE-Proton patches to the pinned Wine tree.

patches/wine-compat/ holds patch sets chosen from Wine Staging 11.4 (the version of
Madeira's Wine) and fixes from GE-Proton's patches/ directory.  Only patches that
change Windows-side (PE) DLL code are taken: nothing that touches wineserver, the
server protocol, ntdll, kernelbase, win32u, wined3d, the loader, the build system or
a Unix display, audio or printing driver.  Madeira replaces those parts with its own
iOS ports, and a patch written for the Linux ones would either not apply or change
an interface the iOS side still implements the old way.  See
patches/wine-compat/SOURCES.md for the list and where each set comes from.

Order: Staging sets by name, each set's patches by file name, then GE-Proton's.
Later patches of a set edit the same files as earlier ones, so a single patch cannot
be tested for "already applied"; the script records the SHA-256 of the whole series
in wine/.ideck-wine-compat instead.  The same series is then skipped, and a checkout
patched with another series is refused: fetch the sources again.
"""
import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATCHES = ROOT / "patches/wine-compat"
MARKER = ".ideck-wine-compat"


def ordered() -> list:
    staging = sorted(p for p in (PATCHES / "staging").glob("*/*.patch"))
    proton = sorted((PATCHES / "ge-proton").glob("*.patch"))
    return staging + proton


def git(wine: Path, *args: str) -> bool:
    return subprocess.run(["git", "-C", str(wine), *args], capture_output=True).returncode == 0


def main(root: str) -> int:
    wine = Path(root) / "wine"
    if not (wine / "dlls/ntdll").is_dir():
        print(f"ERROR: no Wine tree at {wine}", file=sys.stderr)
        return 2
    patches = ordered()
    if not patches:
        print(f"ERROR: no patches under {PATCHES}", file=sys.stderr)
        return 2
    digest = hashlib.sha256()
    for patch in patches:
        digest.update(str(patch.relative_to(PATCHES)).encode() + b"\0" + patch.read_bytes())
    series = digest.hexdigest()
    marker = wine / MARKER
    if marker.is_file():
        if marker.read_text().strip() == series:
            print(f"Wine compatibility patches: already applied ({len(patches)} patches)")
            return 0
        print("ERROR: this Wine tree carries another compatibility series; fetch the sources again", file=sys.stderr)
        return 2
    for patch in patches:
        name = str(patch.relative_to(PATCHES))
        if not git(wine, "apply", "--check", str(patch)):
            print(f"ERROR: {name} does not apply to the pinned Wine tree", file=sys.stderr)
            return 2
        if not git(wine, "apply", str(patch)):
            print(f"ERROR: {name} failed while applying", file=sys.stderr)
            return 2
    marker.write_text(series + "\n")
    print(f"Wine compatibility patches: {len(patches)} applied")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
