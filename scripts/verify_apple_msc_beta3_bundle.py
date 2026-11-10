#!/usr/bin/env python3
"""Check owner's Apple Metal Shader Converter beta-3 provenance through D3D12 IPA staging."""
import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import subprocess
import tempfile
import sys
import zipfile
from pathlib import Path

from prepare_apple_msc_beta3 import (PACKAGE_SHA256, LIBRARY_NAME, LICENSE_NAME, PROVENANCE_NAME, ios_macho_details)

RELATIVE = "d3d12/" + LIBRARY_NAME
REQUIRED = (LIBRARY_NAME, LICENSE_NAME, PROVENANCE_NAME)
EXPECTED_IOS_LIBRARY_BYTES = 30_189_152


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def signature_equivalent(source: Path, staged: Path) -> bool:
    """Accept only a valid re-sign of the exact original Mach-O payload."""
    codesign = shutil.which("codesign")
    if codesign is None:
        return False
    try:
        subprocess.run([codesign, "--verify", "--strict", str(staged)], check=True,
                       capture_output=True, timeout=30)
        with tempfile.TemporaryDirectory(prefix="ideck-msc-signature-") as tmp:
            copies = []
            for index, original in enumerate((source, staged)):
                target = Path(tmp) / f"converter-{index}.dylib"
                shutil.copyfile(original, target)
                # An unsigned development source has no signature to strip.
                data = target.read_bytes()
                count = struct.unpack_from("<I", data, 16)[0]
                offset = 32
                signed = False
                for _ in range(count):
                    command, size = struct.unpack_from("<II", data, offset)
                    if size < 8 or offset + size > len(data):
                        return False
                    signed |= command == 0x1D  # LC_CODE_SIGNATURE
                    offset += size
                if signed:
                    subprocess.run([codesign, "--remove-signature", str(target)], check=True,
                                   capture_output=True, timeout=30)
                copies.append(target.read_bytes())
            return copies[0] == copies[1]
    except (OSError, ValueError, struct.error, subprocess.SubprocessError):
        return False


def verify(source: Path, app: Path, ipa: Path | None = None) -> list[str]:
    errors = []
    paths = [source / "d3d12", app / "d3d12"]
    for directory in paths:
        for name in REQUIRED:
            target = directory / name
            if not target.is_file() or target.is_symlink() or target.stat().st_size == 0:
                errors.append(f"missing real Apple converter provenance artifact: {target}")
    if errors:
        return errors
    try:
        receipt = json.loads((paths[0] / PROVENANCE_NAME).read_text(encoding="utf-8"))
        if receipt.get("package_sha256") != PACKAGE_SHA256:
            errors.append("Apple source package is not the audited 4.0 beta 3")
        if receipt.get("converter") != "Apple Metal Shader Converter 4.0 beta 3":
            errors.append("unexpected Apple converter version")
        if receipt.get("architecture") != "arm64" or receipt.get("platform") != "iOS":
            errors.append("Apple converter is not the iOS ARM64 dylib")
        if receipt.get("device_execution_verified") is not False:
            errors.append("converter receipt falsely claims iPad execution")
        if receipt.get("library_bytes") != EXPECTED_IOS_LIBRARY_BYTES:
            errors.append("Apple 4.0 beta 3 dylib has an unexpected recorded size")
        for directory in paths:
            library_path = directory / LIBRARY_NAME
            library = library_path.read_bytes()
            license_data = (directory / LICENSE_NAME).read_bytes()
            if directory == paths[0] and len(library) != EXPECTED_IOS_LIBRARY_BYTES:
                errors.append(f"wrong Apple beta 3 iOS dylib byte length at {directory}")
            try:
                details = ios_macho_details(library_path)
                for key in ("platform", "minimum_ios", "sdk"):
                    if receipt.get(key) != details.get(key):
                        errors.append(f"Apple converter Mach-O {key} differs from provenance at {directory}")
            except (OSError, ValueError) as exc:
                errors.append(f"invalid iPhoneOS ARM64 Apple converter Mach-O at {directory}: {exc}")
            if not license_data.startswith(b"{\\rtf"):
                errors.append(f"Apple converter license is not an RTF document at {directory}")
            if digest(library) != receipt.get("library_sha256"):
                if directory == paths[0] or not signature_equivalent(paths[0] / LIBRARY_NAME, library_path):
                    errors.append(f"Apple converter does not match audited code/signature: {directory}")
            if digest(license_data) != receipt.get("license_sha256"):
                errors.append(f"Apple converter license does not match source package: {directory}")
            if (directory / PROVENANCE_NAME).read_bytes() != (paths[0] / PROVENANCE_NAME).read_bytes():
                errors.append(f"Apple provenance receipt differs from source: {directory}")
        if ipa is not None:
            with zipfile.ZipFile(ipa, "r") as archive:
                names = archive.namelist()
                for directory in ("d3d12",):
                    for name in REQUIRED:
                        member = f"Payload/iDeck.app/{directory}/{name}"
                        if names.count(member) != 1:
                            errors.append(f"IPA requires one real Apple converter file: {member}")
                            continue
                        if archive.read(member) != (app / directory / name).read_bytes():
                            errors.append(f"IPA Apple converter bytes changed during packaging: {member}")
                manifest = plistlib.loads(archive.read("Payload/iDeck.app/MadeiraRuntimeManifest.plist"))
                if manifest.get("graphicsBackend") != "d3d12" or manifest.get("d3d12Linked") is not True:
                    errors.append("IPA does not declare compiled D3D12 runtime")
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as exc:
        errors.append(f"unable to verify Apple converter provenance: {exc}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    errors = verify(args.source, args.app, args.ipa)
    for message in errors:
        print("ERROR: " + message, file=sys.stderr)
    if errors:
        return 2
    print("PASS: source, staged iOS app and optional IPA match the owner-supplied Apple 4.0 beta 3 library/license.")
    print("NOT PROVEN: library redistribution eligibility, signed device execution, shader conversion or games.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
