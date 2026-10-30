#!/usr/bin/env python3
"""Validate Wine 11.4 ARM64EC and iPhoneOS Unix archives after a real source build.

This is a compile-time gate, not a guest-process or JIT execution test.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import verify_madeira_component_outputs as compiled

WINE_VERSION = "Wine version 11.4"
BUILD_CONFIG = "wine/build-arm64ec/config.status"
NATIVE_CONFIG = "wine/build-macos/include/config.h"
SERVER_BUILDER = "build/wineserver/build.sh"
GENERATED_HEADERS = ("wtypes.h", "mfobjects.h", "mftransform.h", "dwrite.h", "dwrite_3.h")
ARTIFACTS = (*compiled.FEX_ARCHIVES, *compiled.FEX_PE, *compiled.WINE_ARCHIVES, *compiled.WINE_PE)


def inspect_sources(root: Path) -> list[str]:
    errors = []
    version = root / "wine/VERSION"
    if not version.is_file() or version.read_text(encoding="utf-8").strip() != WINE_VERSION:
        errors.append(f"expected published Madeira Wine {WINE_VERSION}: {version}")

    config = root / BUILD_CONFIG
    if not config.is_file() or config.stat().st_size < 100:
        errors.append(f"ARM64EC Wine configuration is missing: {config}")
    elif not re.search(r"--enable-archs(?:=|\s+)arm64ec\b", config.read_text(encoding="utf-8", errors="replace")):
        errors.append(f"Wine was not configured for ARM64EC: {config}")

    native = root / NATIVE_CONFIG
    if not native.is_file() or native.stat().st_size < 100:
        errors.append(f"macOS Wine build configuration missing: {native}")

    for tree in ("wine/build-macos", "wine/build-arm64ec"):
        for name in GENERATED_HEADERS:
            file = root / tree / "include" / name
            if not file.is_file() or file.stat().st_size < 64:
                errors.append(f"Wine-generated SDK header missing: {file}")

    builder = root / SERVER_BUILDER
    if not builder.is_file() or "SERVER_SOURCES=" not in builder.read_text(encoding="utf-8"):
        errors.append(f"Wine wineserver must be rebuilt from published sources: {builder}")
    return errors


def verify(root: Path, source_revision: str) -> tuple[list[str], dict]:
    issues = compiled.verify(root, "wine")
    issues.extend(inspect_sources(root))
    hashes = {}
    for relative in ARTIFACTS:
        target = root / relative
        if not target.is_file() or target.stat().st_size < 1024:
            issues.append(f"real compiled Wine/FEX artifact missing: {target}")
            continue
        digest = hashlib.sha256()
        with target.open("rb") as binary:
            for chunk in iter(lambda: binary.read(1024 * 1024), b""):
                digest.update(chunk)
        hashes[relative] = {"sha256": digest.hexdigest(), "bytes": target.stat().st_size}

    receipt = {
        "stage": 4,
        "source_revision": source_revision,
        "wine_version": WINE_VERSION,
        "profile": "d3d11-x86_64-only",
        "validated": not issues,
        "artifact_hashes": hashes,
        "not_validated": [
            "Wine PE process starts on an iPad",
            "wineserver thread lifecycle on an iPad",
            "live JIT allocation and StikDebug session",
            "Windows application graphics/audio/controls",
        ],
    }
    return issues, receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("vendor/Madeira"))
    parser.add_argument("--revision", required=True)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        parser.error("--revision requires an exact 40-character lowercase SHA")
    try:
        issues, receipt = verify(args.root, args.revision)
    except (OSError, ValueError) as exc:
        print(f"ERROR: Wine phase-4 validation failed: {exc}", file=sys.stderr)
        return 2
    if issues:
        for issue in issues:
            print("ERROR: " + issue, file=sys.stderr)
        return 2
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print("PASS: pinned Wine 11.4 ARM64EC PE, iPhoneOS Unix archives and wineserver source-build inputs.")
    print("NOT VERIFIED: Wine guest execution, on-device JIT or game display.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
