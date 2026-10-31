#!/usr/bin/env python3
"""Validate actual DXMT/D3D11 source-built Metal/iPhoneOS and ARM64EC outputs.

Only verifies compilation, PE architecture, and build provenance. Real game
frames, the iPad Metal compositor, and Wine process startup are not tested.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import verify_madeira_component_outputs as compiled

MODULES = ("d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll")
SHADERS = ("air_msad", "air_samplepos", "air_tessellation")
IOS_ARCHIVE = "app/Madeira/libdxmt_combined.a"
DXMT_ARTIFACTS = (IOS_ARCHIVE,) + tuple(
    f"app/Madeira/{architecture}-windows/{name}"
    for architecture in ("aarch64", "arm64ec")
    for name in MODULES
)
REQUIRED_BUILDS = (
    "dxmt/build-pe/build.ninja",
    "dxmt/build-arm64ec/build.ninja",
)
SOURCE_REVISION = "c2c1b03a9e36ef986c980b9eae3c14d05a372db1"


def source_errors(root: Path) -> list[str]:
    errors = []
    for name in REQUIRED_BUILDS:
        path = root / name
        if not path.is_file() or path.stat().st_size < 64:
            errors.append(f"DXMT Meson source-build configuration absent: {path}")

    for name in SHADERS:
        metal = root / "dxmt/src/airconv/shaders" / f"{name}.metal"
        air = root / "build/dxmt-ios/shader-headers" / f"{name}.air"
        header = root / "build/dxmt-ios/shader-headers" / f"{name}.h"
        for file in (metal, air, header):
            if not file.is_file() or file.stat().st_size < 16:
                errors.append(f"real compiled DXMT Metal shader/input missing: {file}")
    return errors


def artifact_errors(root: Path) -> list[str]:
    errors = []
    errors.extend(compiled.verify(root, "dxmt"))
    errors.extend(source_errors(root))
    archive = root / IOS_ARCHIVE
    if compiled.verify_archive(archive):
        # The stage architecture verifier also checks this archive; retain one
        # consistent error even when a separate DXMT run is invoked.
        if not any(str(archive) in error for error in errors):
            errors.append(f"iPhoneOS arm64 DXMT combined archive missing/invalid: {archive}")
    for architecture in ("aarch64", "arm64ec"):
        for module in MODULES:
            path = root / f"app/Madeira/{architecture}-windows/{module}"
            if not path.is_file() or path.stat().st_size < 1024:
                errors.append(f"DXMT {architecture} frontend missing: {path}")
                continue
            problem = compiled.bundle._pe_arch_error(path, require_arm64ec=(architecture == "arm64ec"))
            if problem:
                errors.append(problem)
    return errors


def verify(root: Path, revision: str) -> tuple[list[str], dict]:
    errors = artifact_errors(root)
    files = {}
    for name in DXMT_ARTIFACTS:
        file = root / name
        if not file.is_file() or file.stat().st_size < 1024:
            errors.append(f"DXMT compilation output missing: {file}")
            continue
        digest = hashlib.sha256()
        with file.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        files[name] = {"bytes": file.stat().st_size, "sha256": digest.hexdigest()}
    if len(files) != len(DXMT_ARTIFACTS):
        errors.append("DXMT receipt has fewer than nine genuine native graphics files")
    return errors, {
        "stage": 5,
        "source_revision": revision,
        "backend": "dxmt-d3d11-metal",
        "profile": "d3d11-x86_64-only",
        "validated": not errors,
        "artifact_hashes": files,
        "not_validated": [
            "Metal on-device frame presentation",
            "Windows guest x86-64 D3D11 rendering",
            "StikDebug executable-memory allocation",
            "actual iPad audio, input, and Wine process lifecycle",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("vendor/Madeira"))
    parser.add_argument("--revision", default=SOURCE_REVISION)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        parser.error("--revision must be a 40-character lowercase source commit hash")
    try:
        errors, receipt = verify(args.root, args.revision)
    except (OSError, ValueError) as exc:
        print(f"ERROR: DXMT native output validation failed: {exc}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 2
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("PASS: iPhoneOS arm64 DXMT and ARM64/ARM64EC D3D11/DXGI/D3D10/Metal frontends compiled.")
    print("NOT VERIFIED: on-device Wine guest first frame, audio or JIT.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
