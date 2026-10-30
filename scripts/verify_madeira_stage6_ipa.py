#!/usr/bin/env python3
"""Fail-closed audit of a compiled, linked and packaged Madeira D3D11 iOS IPA."""
import argparse
import hashlib
import json
import plistlib
import re
import stat
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath

import verify_madeira_bundle as bundle

ROOT = "Payload/iDeck.app/"
REQUIRED_SYMBOLS = tuple(
    symbol for symbol in bundle.SYMBOLS if symbol not in bundle.D3D12_SYMBOLS
)
GRAPHICS = ("d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll")
IPA_PAYLOADS = (
    "Info.plist",
    "iDeck",
    "MadeiraRuntimeManifest.plist",
    "PlugIns/VPNExtension.appex/Info.plist",
    "arm64ec-windows/ntdll.dll",
    "arm64ec-windows/xtajit64.dll",
    "MadeiraRuntime/arm64ec-windows/ntdll.dll",
    "MadeiraRuntime/arm64ec-windows/xtajit64.dll",
    "licenses/LuaJIT-MIT.txt",
) + tuple(
    f"{prefix}/{machine}-windows/{name}"
    for prefix in ("", "MadeiraRuntime")
    for machine in ("aarch64", "arm64ec")
    for name in GRAPHICS
)
FORBIDDEN_NAMES = {
    "d3d12.dll", "d3d12core.dll", "madeira_d3d12.dll",
    "libmetalirconverter.dylib", "xtajit.dll", "wow64.dll", "wow64win.dll",
}
EXPECTED_MANIFEST = {
    "runtimeABI": 1,
    "fexInProcess": True,
    "wineInProcess": True,
    "dxmtLinked": True,
    "d3d12Linked": False,
    "graphicsBackend": "d3d11",
    "wow64Enabled": False,
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def symbols_and_architecture(app: Path) -> list[str]:
    errors = []
    images = [app / "iDeck"]
    debug = app / "iDeck.debug.dylib"
    if debug.exists():
        images.append(debug)
    exports = set()
    for image in images:
        if not image.is_file() or image.stat().st_size < 1024:
            errors.append(f"missing or implausibly small compiled Mach-O executable: {image}")
            continue
        try:
            archs = subprocess.run(
                ["xcrun", "lipo", "-archs", str(image)], capture_output=True,
                check=True, text=True,
            ).stdout.split()
            if "arm64" not in archs:
                errors.append(f"linked iOS image lacks ARM64: {image} ({archs})")
            nm = subprocess.run(
                ["xcrun", "nm", "-arch", "arm64", "-gU", str(image)],
                capture_output=True, check=True, text=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as exc:
            errors.append(f"cannot inspect compiled native Mach-O image {image}: {exc}")
            continue
        exports.update(re.findall(r"(?m)^.*\s_([A-Za-z][A-Za-z0-9_]*)\s*$", nm))
    errors.extend(
        f"FEX/Wine/DXMT native symbol absent from linked iDeck Mach-O: {symbol}"
        for symbol in REQUIRED_SYMBOLS if symbol not in exports
    )
    return errors


def validate_manifest(data: bytes, label: str) -> list[str]:
    try:
        manifest = plistlib.loads(data)
    except (ValueError, TypeError, plistlib.InvalidFileException) as exc:
        return [f"invalid runtime manifest at {label}: {exc}"]
    return [
        f"invalid D3D11 native runtime manifest field {key} at {label}: {manifest.get(key)!r}"
        for key, expected in EXPECTED_MANIFEST.items()
        if manifest.get(key) != expected or type(manifest.get(key)) is not type(expected)
    ]


def inspect(app: Path, ipa: Path) -> tuple[list[str], dict]:
    errors = []
    if not app.is_dir():
        return [f"staged native iDeck.app does not exist: {app}"], {}
    if not ipa.is_file() or ipa.stat().st_size < 1024:
        return [f"native IPA missing or implausibly small: {ipa}"], {}

    errors.extend(symbols_and_architecture(app))
    manifest_file = app / "MadeiraRuntimeManifest.plist"
    if not manifest_file.is_file():
        errors.append(f"missing verified native runtime manifest: {manifest_file}")
    else:
        errors.extend(validate_manifest(manifest_file.read_bytes(), str(manifest_file)))

    try:
        with zipfile.ZipFile(ipa, "r") as archive:
            infos = archive.infolist()
            names = [entry.filename for entry in infos]
            if len(names) != len(set(names)):
                errors.append("IPA contains duplicate ZIP entries")
            members = set(names)
            for entry in infos:
                name = entry.filename
                parts = PurePosixPath(name).parts
                if (
                    name.startswith("/")
                    or "\\" in name
                    or ".." in parts
                    or not (name == "Payload/" or name.startswith(ROOT))
                ):
                    errors.append(f"IPA contains unsafe or unexpected ZIP path: {name}")
                if (
                    stat.S_ISLNK(entry.external_attr >> 16)
                    and (
                        name.startswith(ROOT + "MadeiraRuntime/")
                        or name.startswith(ROOT + "arm64ec-windows/")
                        or name.startswith(ROOT + "aarch64-windows/")
                    )
                ):
                    errors.append(f"IPA runtime contains an unsupported Unix symlink: {name}")
                if name.startswith(ROOT):
                    tail = name[len(ROOT):].lower()
                    if (
                        PurePosixPath(tail).name in FORBIDDEN_NAMES
                        or "d3d12" in PurePosixPath(tail).parts
                        or "i386-windows" in PurePosixPath(tail).parts
                    ):
                        errors.append(f"D3D11 IPA illegally includes D3D12/WoW64 asset: {name}")
            for relative in IPA_PAYLOADS:
                archive_name = ROOT + relative.lstrip("/")
                if archive_name not in members:
                    errors.append(f"real native IPA is missing required runtime asset: {archive_name}")
                    continue
                staged = app / relative.lstrip("/")
                if not staged.is_file() or staged.is_symlink():
                    errors.append(f"required runtime asset is not a staged real file: {staged}")
                    continue
                with archive.open(archive_name) as zipped:
                    digest = hashlib.sha256()
                    for block in iter(lambda: zipped.read(1024 * 1024), b""):
                        digest.update(block)
                if digest.hexdigest() != sha256_file(staged):
                    errors.append(f"IPA resource differs from staged binary: {archive_name}")
            archive_manifest = ROOT + "MadeiraRuntimeManifest.plist"
            if archive_manifest in members:
                errors.extend(validate_manifest(
                    archive.read(archive_manifest), archive_manifest
                ))
            info = ROOT + "Info.plist"
            if info in members:
                try:
                    bundle_info = plistlib.loads(archive.read(info))
                    if bundle_info.get("CFBundleIdentifier") != "com.ideck.ideck":
                        errors.append("IPA main app bundle identifier differs from com.ideck.ideck")
                except (ValueError, TypeError, plistlib.InvalidFileException) as exc:
                    errors.append(f"invalid IPA Info.plist: {exc}")
            vpn = ROOT + "PlugIns/VPNExtension.appex/Info.plist"
            if vpn in members:
                try:
                    vpn_info = plistlib.loads(archive.read(vpn))
                    if vpn_info.get("CFBundleIdentifier") != "com.ideck.ideck.VPNExtension":
                        errors.append("IPA VPN extension has incorrect bundle identifier")
                except (ValueError, TypeError, plistlib.InvalidFileException) as exc:
                    errors.append(f"invalid IPA VPN extension Info.plist: {exc}")
    except (OSError, zipfile.BadZipFile, RuntimeError, EOFError, ValueError) as exc:
        errors.append(f"invalid packaged native IPA: {exc}")

    receipt = {
        "stage": 6,
        "graphics": "d3d11",
        "wow64": False,
        "d3d12": False,
        "linked_macho_symbol_count": len(REQUIRED_SYMBOLS),
        "ipa_sha256": sha256_file(ipa),
        "ipa_bytes": ipa.stat().st_size,
        "validated": not errors,
        "not_validated": [
            "real iPad runtime execution",
            "StikDebug executable JIT mapping",
            "Windows guest game first frame and audio",
        ],
    }
    return errors, receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    try:
        errors, receipt = inspect(args.app, args.ipa)
    except (OSError, ValueError) as exc:
        print(f"ERROR: native Stage 6 IPA audit aborted: {exc}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print("ERROR: " + error, file=sys.stderr)
        return 2
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("PASS: real FEX/Wine/DXMT Mach-O exports, D3D11 PE payloads and unsigned IPA contents verified.")
    print("NOT VERIFIED: StikDebug JIT, live Windows execution and first rendered frame on iPad.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
