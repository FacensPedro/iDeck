#!/usr/bin/env python3
"""Fail closed when an iDeck Madeira app lacks source and license notices.

This is a distribution preflight, NOT a legal certification. The complete
corresponding source, build instructions, LGPL relinking obligations and
third-party permission requirements must still be addressed separately.
"""
import argparse
import sys
from pathlib import Path

NOTICE_FILES = {
    "legal/LICENSE": ("GNU GENERAL PUBLIC LICENSE", "Version 3"),
    "legal/THIRD-PARTY-NOTICES.md": ("Third-party components", "GPL-3.0-or-later"),
    "licenses/FEX-MIT.txt": ("MIT License",),
    "licenses/DXMT-MIT.txt": ("MIT License",),
    "licenses/LGPL-2.1.txt": ("GNU LESSER GENERAL PUBLIC LICENSE",),
    "licenses/LGPL-3.0.txt": ("GNU LESSER GENERAL PUBLIC LICENSE",),
    "licenses/LLVM-Apache-2.0-with-exception.txt": ("Apache License",),
    "licenses/rpmalloc-0BSD.txt": ("Permission",),
    "licenses/THIRD-PARTY-NOTICES.txt": ("Madeira", "GPL-3.0-or-later"),
    "licenses/LuaJIT-MIT.txt": ("MIT",),
}


def verify(app: Path, graphics: str) -> list[str]:
    if graphics not in ("d3d11", "d3d12"):
        raise ValueError(f"unsupported Madeira graphics profile: {graphics}")
    issues: list[str] = []
    for name, markers in NOTICE_FILES.items():
        file = app / name
        if not file.is_file() or file.stat().st_size < 32:
            issues.append(f"missing or incomplete required legal notice: {file}")
            continue
        content = file.read_text(encoding="utf-8", errors="replace")
        if not all(marker in content for marker in markers):
            issues.append(f"invalid or mismatched license notice: {file}")
    if graphics == "d3d11":
        for name in ("d3d12",):
            path = app / name
            if path.exists() or path.is_symlink():
                issues.append(f"converter-free D3D11 IPA contains a D3D12 directory: {path}")
        if any(path.name == "libmetalirconverter.dylib" for path in app.rglob("*")):
            issues.append("converter-free D3D11 IPA contains Apple's Metal Shader Converter")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--graphics", choices=("d3d11", "d3d12", "unified"), required=True)
    args = parser.parse_args()
    if args.graphics == "unified":   # DXMT + Madeira D3D12: the d3d12 payload
        args.graphics = "d3d12"
    try:
        errors = verify(args.app, args.graphics)
    except (OSError, ValueError) as exc:
        errors = [str(exc)]
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print("PASS: Madeira GPL/LGPL/MIT license notices present.")
    print("NOT VERIFIED: full corresponding-source, LGPL relinkability and redistribution rights.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
