#!/usr/bin/env python3
"""Record the actual Madeira IPA profile after strict native bundle verification."""

import argparse
import os
import plistlib
import subprocess
import sys
from pathlib import Path


def source_commit() -> str:
    """The commit the IPA was built from, for benchmark reports."""
    sha = os.environ.get("GITHUB_SHA", "").strip()
    if not sha:
        try:
            sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                                 check=True, cwd=Path(__file__).resolve().parent).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            sha = ""
    return sha if len(sha) == 40 and all(c in "0123456789abcdef" for c in sha) else "unknown"


def stamp(app: Path, require_native: bool = False, expected_graphics: str | None = None) -> dict:
    manifest = app / "MadeiraRuntimeManifest.plist"
    if manifest.is_file():
        with manifest.open("rb") as handle:
            native = plistlib.load(handle)
        if not isinstance(native, dict) or not all(
            native.get(field) is True for field in ("fexInProcess", "wineInProcess", "dxmtLinked")
        ):
            raise ValueError("Invalid native runtime manifest")
        graphics = native.get("graphicsBackend")
        if graphics not in ("d3d11", "d3d12") or native.get("d3d12Linked") is not (graphics == "d3d12"):
            raise ValueError("Native runtime graphics profile is invalid")
        if expected_graphics and graphics != expected_graphics:
            raise ValueError("Native runtime graphics profile differs from requested graphics")
        wow64 = native.get("wow64Enabled") is True
        converter = (app / "d3d12/libmetalirconverter.dylib").is_file()
        if converter != (graphics == "d3d12"):
            raise ValueError("Apple shader converter presence conflicts with native graphics backend")
        if wow64 and not (app / "i386-windows/ntdll.dll").is_file():
            raise ValueError("WoW64 manifest advertises missing i386 Windows DLLs")
        mono = (app / "wine-mono/bin/libmono-2.0-x86.dll").is_file()
        kind = "madeira-native"
    else:
        if require_native:
            raise ValueError("Native runtime requested but the packaged IPA is interface-only")
        if (app / "arm64ec-windows/ntdll.dll").is_file() or (app / "d3d12/libmetalirconverter.dylib").is_file():
            raise ValueError("Interface-only IPA unexpectedly contains a native Windows payload")
        kind, graphics, wow64, mono, converter = "interface-only", "none", False, False, False

    profile = {
        "profileSchema": 1,
        "runtimeKind": kind,
        "graphicsBackend": graphics,
        "wow64Enabled": wow64,
        "wineMonoBundled": mono,
        "metalShaderConverterBundled": converter,
        "sourceCommit": source_commit(),
    }
    with (app / "iDeckRuntimeProfile.plist").open("wb") as handle:
        plistlib.dump(profile, handle, sort_keys=True)
    return profile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--require-native", action="store_true")
    parser.add_argument("--expected-graphics", choices=("d3d11", "d3d12"))
    args = parser.parse_args()
    try:
        profile = stamp(args.app, args.require_native, args.expected_graphics)
    except (ValueError, OSError, plistlib.InvalidFileException) as exc:
        print(f"ERROR: iDeck IPA profile: {exc}", file=sys.stderr)
        return 2
    print("iDeck IPA runtime profile verified:", profile)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
