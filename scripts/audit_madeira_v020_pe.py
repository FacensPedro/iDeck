#!/usr/bin/env python3
"""Compare a built iDeck native PE farm with Madeira v0.2.0 without mixing ABIs.

Use an unpacked v0.2.0 Madeira.app (or its source app/Madeira) and the
unpacked iDeck.app as input. No binary download or redistribution occurs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ARCHES = ("arm64ec-windows", "aarch64-windows", "i386-windows")
D3D12 = frozenset(("d3d12.dll", "d3d12core.dll", "madeira_d3d12.dll"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan(path: Path) -> dict[str, Path]:
    if not path.is_dir():
        return {}
    return {
        item.name.casefold(): item
        for item in path.iterdir()
        if item.is_file() and item.suffix.casefold() in (".dll", ".exe")
    }


def audit(madeira: Path, ideck: Path, *, graphics: str, wow64: bool) -> dict:
    if graphics not in ("d3d11", "d3d12"):
        raise ValueError("graphics must be d3d11 or d3d12")
    missing: list[str] = []
    changed: list[str] = []
    identical: list[str] = []
    examined = 0
    skipped: list[str] = []
    for arch in ARCHES:
        if arch == "i386-windows" and not wow64:
            continue
        source = scan(madeira / arch)
        target = scan(ideck / arch)
        for name, path in sorted(source.items()):
            logical = f"{arch}/{name}"
            if graphics == "d3d11" and name in D3D12:
                skipped.append(logical)
                continue
            examined += 1
            installed = target.get(name)
            if installed is None:
                missing.append(logical)
            elif sha256(path) != sha256(installed):
                changed.append(logical)
            else:
                identical.append(logical)
    return {
        "reference": "Madeira v0.2.0",
        "graphics": graphics,
        "wow64": wow64,
        "examined": examined,
        "missing": missing,
        "different_binary": changed,
        "identical_binary": len(identical),
        "optional_profile_exclusions": skipped,
        "note": (
            "Binary differences are informational, not authorization to combine "
            "Wine/FEX/DXMT binaries from incompatible revisions. These folders "
            "do not contain the six optional Steam FFmpeg DLLs or SDL3.dll."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--madeira-v020", type=Path, required=True,
                        help="Extracted Madeira v0.2.0 app/Madeira or Payload/Madeira.app")
    parser.add_argument("--ideck", type=Path, required=True,
                        help="Native iDeck.app or staged app/Madeira directory")
    parser.add_argument("--graphics", choices=("d3d11", "d3d12"), default="d3d11")
    parser.add_argument("--wow64", action="store_true")
    parser.add_argument("--fail-on-missing", action="store_true")
    args = parser.parse_args()
    result = audit(args.madeira_v020, args.ideck, graphics=args.graphics, wow64=args.wow64)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 2 if args.fail_on_missing and result["missing"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
