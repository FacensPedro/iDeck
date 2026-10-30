#!/usr/bin/env python3
"""Verify actual per-stage Madeira iPhoneOS archives and ARM64EC PE images."""
import argparse
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "scripts/verify_madeira_bundle.py"
spec = importlib.util.spec_from_file_location("ideck_bundle_validator", BUNDLE)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)

FEX_ARCHIVES = (
    "FEX/build-ios/FEXCore/Source/libFEXCore.a",
    "FEX/build-ios/FEXCore/Source/libFEXCore_Base.a",
    "FEX/build-ios/FEXCore/Source/libJemallocLibs.a",
)
WINE_ARCHIVES = (
    "app/Madeira/libntdll_unix.a",
    "app/Madeira/libwineserver.a",
    "app/Madeira/libwin32u_unix.a",
)
DXMT_ARCHIVES = ("app/Madeira/libdxmt_combined.a",)
FEX_PE = ("app/Madeira/arm64ec-windows/xtajit64.dll",)
WINE_PE = ("app/Madeira/arm64ec-windows/ntdll.dll",)
DXMT_PE = (
    "app/Madeira/arm64ec-windows/d3d11.dll",
    "app/Madeira/arm64ec-windows/dxgi.dll",
    "app/Madeira/arm64ec-windows/d3d10core.dll",
    "app/Madeira/arm64ec-windows/winemetal.dll",
)


def verify_archive(path: Path) -> str | None:
    if not path.is_file() or path.stat().st_size < 1024:
        return f"missing or implausibly small iPhoneOS library: {path}"
    try:
        result = subprocess.run(
            ["xcrun", "lipo", "-archs", str(path)],
            check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        return f"unreadable real Mach-O static archive: {path}: {exc}"
    if result.stdout.strip() != "arm64":
        return f"iPhoneOS static archive has unexpected architecture: {path}: {result.stdout.strip()}"
    return None


def verify_pe(path: Path) -> str | None:
    if not path.is_file() or path.stat().st_size < 1024:
        return f"missing or implausibly small ARM64EC Windows PE: {path}"
    try:
        return bundle._pe_arch_error(path, require_arm64ec=True)
    except (OSError, ValueError) as exc:
        return f"invalid compiled ARM64EC Windows PE: {path}: {exc}"


def verify(root: Path, stage: str) -> list[str]:
    if stage not in ("fex", "wine", "dxmt"):
        raise ValueError(f"invalid Madeira compilation stage: {stage}")
    archives = FEX_ARCHIVES
    images = FEX_PE
    if stage in ("wine", "dxmt"):
        archives += WINE_ARCHIVES
        images += WINE_PE
    if stage == "dxmt":
        archives += DXMT_ARCHIVES
        images += DXMT_PE
    errors = []
    for name in archives:
        error = verify_archive(root / name)
        if error:
            errors.append(error)
    for name in images:
        error = verify_pe(root / name)
        if error:
            errors.append(error)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT / "vendor/Madeira")
    parser.add_argument("--stage", choices=("fex", "wine", "dxmt"), required=True)
    args = parser.parse_args()
    try:
        failures = verify(args.root, args.stage)
    except (OSError, ValueError) as exc:
        failures = [str(exc)]
    if failures:
        for error in failures:
            print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(f"PASS: real iPhoneOS ARM64 + Windows ARM64EC Madeira stage {args.stage} verified.")
    print("NOT VERIFIED: final Xcode linkage, iPad JIT, guest execution or graphics output.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
