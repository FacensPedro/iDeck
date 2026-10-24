#!/usr/bin/env python3
"""Audit a built iOS .app before claiming that Madeira is integrated."""
import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

SYMBOLS = (
    "ideck_madeira_launch_v1",
    "fex_initialize",
    "wineserver_start",
    "wine_process_start",
    "madeira_get_present_count",
    "madeira_d3d12_canary_run",
)
PE_FILES = (
    "aarch64-windows/d3d11.dll",
    "aarch64-windows/dxgi.dll",
    "arm64ec-windows/d3d12.dll",
    "arm64ec-windows/d3d12core.dll",
    "arm64ec-windows/xtajit64.dll",
    "arm64ec-windows/winemetal.dll",
)


def inspect(app: Path) -> list[str]:
    errors = []
    executable = app / "iDeck"
    if not executable.is_file():
        return [f"missing app executable: {executable}"]
    try:
        result = subprocess.run(
            ["xcrun", "nm", "-arch", "arm64", "-gU", str(executable)],
            check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        exported = set(re.findall(r"(?m)^.*\s_([A-Za-z][A-Za-z0-9_]*)\s*$", result.stdout))
        errors.extend(f"native symbol not linked/exported: {name}"
                      for name in SYMBOLS if name not in exported)
    except (OSError, subprocess.CalledProcessError) as exc:
        errors.append(f"unable to inspect linked arm64 symbols: {exc}")

    runtime = app / "MadeiraRuntime"
    for path in PE_FILES:
        dll = runtime / path
        if not dll.is_file() or dll.stat().st_size < 1024:
            errors.append(f"missing compiled Windows PE library: {dll}")
        elif dll.open("rb").read(2) != b"MZ":
            errors.append(f"invalid PE signature: {dll}")
    converter = runtime / "d3d12" / "libmetalirconverter.dylib"
    if not converter.is_file() or converter.stat().st_size < 1024:
        errors.append(f"missing or empty iOS shader converter dependency: {converter}")

    prefix = app / "prefix-template.tar.gz"
    if not prefix.is_file() or prefix.stat().st_size < 1024:
        errors.append(f"missing Madeira Wine prefix template: {prefix}")
    elif prefix.open("rb").read(2) != b"\\x1f\\x8b":
        errors.append(f"invalid Wine prefix gzip signature: {prefix}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--require", action="store_true",
                        help="fail if native runtime is absent; never produce a false-ready IPA")
    options = parser.parse_args()
    app = options.app
    manifest = app / "MadeiraRuntimeManifest.plist"
    if manifest.exists():
        manifest.unlink()

    errors = inspect(app)
    if errors:
        for error in errors:
            print(f"Madeira check: {error}", file=sys.stderr)
        if options.require:
            print("Native runtime build FAILED verification.", file=sys.stderr)
            return 1
        print("Packaging interface-only IPA. Windows execution remains disabled.")
        return 0

    with manifest.open("wb") as handle:
        plistlib.dump({
            "runtimeABI": 1,
            "fexInProcess": True,
            "wineInProcess": True,
            "dxmtLinked": True,
            "d3d12Linked": True,
        }, handle)
    print("Native payload and symbols found. Device integration testing is still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
