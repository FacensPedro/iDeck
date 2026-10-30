#!/usr/bin/env python3
"""Verify reproducible iOS FEXCore and ARM64EC host-module configuration.

This validates compiled files and the *actual* CMake caches. It does not
initialize executable memory or attest that a debugger is attached on iPad.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

import verify_madeira_component_outputs as compiled

ARTIFACTS = (
    *compiled.FEX_ARCHIVES,
    *compiled.FEX_PE,
)
IOS_CACHE = "FEX/build-ios/CMakeCache.txt"
ARM64EC_CACHE = "FEX/build-arm64ec/CMakeCache.txt"


def read_cache(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise ValueError(f"FEX build configuration missing: {path}")
    values = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith(("//", "#")) or "=" not in line:
            continue
        key_type, value = line.split("=", 1)
        if ":" in key_type:
            key, _ = key_type.split(":", 1)
            values[key] = value
    return values


def check_cache(cache: dict[str, str], name: str) -> list[str]:
    if name == "ios":
        exact = {"TUNE_CPU": "none", "CMAKE_OSX_ARCHITECTURES": "arm64"}
        flags = {}
    elif name == "arm64ec":
        exact = {
            "FEX_IOS_HOST_BUILD": "ON",
            "MINGW_TRIPLE": "arm64ec-w64-mingw32",
            "ENABLE_LTO": "OFF",
        }
        flags = {
            "CMAKE_C_FLAGS": "-DFEX_IOS_HOST=1",
            "CMAKE_CXX_FLAGS": "-DFEX_IOS_HOST=1",
            "CMAKE_ASM_FLAGS": "-DFEX_IOS_HOST=1",
        }
    else:
        raise ValueError(f"unknown FEX configuration: {name}")
    errors = [
        f"{name} FEX CMake option {key}: expected {expected}, got {cache.get(key)!r}"
        for key, expected in exact.items()
        if cache.get(key) != expected
    ]
    errors.extend(
        f"{name} FEX CMake option {key}: missing {required}"
        for key, required in flags.items()
        if required not in cache.get(key, "").split()
    )
    return errors


def verify(root: Path, source_revision: str) -> tuple[list[str], dict]:
    errors = compiled.verify(root, "fex")
    for file, name in ((IOS_CACHE, "ios"), (ARM64EC_CACHE, "arm64ec")):
        try:
            errors.extend(check_cache(read_cache(root / file), name))
        except (OSError, ValueError) as exc:
            errors.append(str(exc))
    artifact_hashes = {}
    for name in ARTIFACTS:
        path = root / name
        if path.is_file() and path.stat().st_size >= 1024:
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for piece in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(piece)
            artifact_hashes[name] = {"sha256": digest.hexdigest(), "bytes": path.stat().st_size}
    if len(artifact_hashes) != len(ARTIFACTS):
        errors.append("FEX stage manifest is incomplete: compiled artifacts missing")
    receipt = {
        "stage": 3,
        "source_revision": source_revision,
        "profile": "d3d11-x86_64-only",
        "validated": not errors,
        "artifact_hashes": artifact_hashes,
        "not_validated": [
            "iPad JIT memory allocation",
            "StikDebug debugger attachment",
            "guest x86-64 instruction execution",
            "Windows first frame",
        ],
    }
    return errors, receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("vendor/Madeira"))
    parser.add_argument("--revision", required=True, help="full pinned Madeira commit SHA")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if len(args.revision) != 40 or any(c not in "0123456789abcdef" for c in args.revision):
        parser.error("--revision must be the exact lowercase 40-character Madeira commit hash")
    try:
        errors, receipt = verify(args.root, args.revision)
    except (OSError, ValueError) as exc:
        print(f"ERROR: cannot inspect compiled FEX stage: {exc}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print("ERROR: " + error, file=sys.stderr)
        return 2
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("PASS: FEXCore iPhoneOS ARM64 and xtajit64.dll ARM64EC compiled and verified.")
    print("NOT VERIFIED: FEX JIT executing on the physical iPad.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
