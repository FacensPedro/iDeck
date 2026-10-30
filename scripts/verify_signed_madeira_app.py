#!/usr/bin/env python3
"""Read-only check of a signed, provisioned native Madeira iOS app.

Run the strict Madeira bundle verifier BEFORE signing: it updates the runtime
manifest, which would invalidate a signature if invoked on the signed app.
This tool never changes any file and never claims Windows execution succeeded.
"""
import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

REQUIRED_ENTITLEMENTS = (
    "com.apple.developer.kernel.increased-memory-limit",
    "com.apple.developer.kernel.extended-virtual-addressing",
)


def command(*args: str) -> subprocess.CompletedProcess:
    result = subprocess.run(args, capture_output=True, check=False)
    if result.returncode:
        error = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"{' '.join(args)} failed: {error}")
    return result


def team_id(path: Path) -> str:
    metadata = command("codesign", "-dvv", str(path)).stderr.decode(
        "utf-8", errors="replace"
    )
    if "Signature=adhoc" in metadata:
        raise ValueError(f"ad-hoc signature is not valid device provisioning: {path}")
    match = re.search(r"(?m)^TeamIdentifier=([^\s]+)", metadata)
    if not match or match.group(1) in ("not", "unset", "none"):
        raise ValueError(f"no signed TeamIdentifier found: {path}")
    return match.group(1)


def verify(app: Path) -> None:
    binary = app / "iDeck"
    manifest = app / "MadeiraRuntimeManifest.plist"
    profile = app / "embedded.mobileprovision"
    converter = app / "d3d12/libmetalirconverter.dylib"
    mirror = app / "MadeiraRuntime/d3d12/libmetalirconverter.dylib"
    for file in (binary, manifest, profile, converter, mirror):
        if not file.is_file() or not file.stat().st_size:
            raise ValueError(f"missing signed native app input: {file}")

    with manifest.open("rb") as stream:
        metadata = plistlib.load(stream)
    for key in ("fexInProcess", "wineInProcess", "dxmtLinked", "d3d12Linked"):
        if metadata.get(key) is not True:
            raise ValueError(f"native bundle manifest does not prove {key}")
    command("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    app_team = team_id(app)

    signed = plistlib.loads(
        command("codesign", "-d", "--entitlements", ":-", str(app)).stdout
    )
    profile_data = plistlib.loads(
        command("security", "cms", "-D", "-i", str(profile)).stdout
    )
    authorized = profile_data.get("Entitlements", {})
    for entitlement in REQUIRED_ENTITLEMENTS:
        if signed.get(entitlement) is not True:
            raise ValueError(f"missing signed entitlement: {entitlement}")
        if authorized.get(entitlement) is not True:
            raise ValueError(f"provisioning profile does not authorize: {entitlement}")
    if authorized.get("com.apple.developer.team-identifier") != app_team:
        raise ValueError("signing identity does not match the provisioning team")
    if not profile_data.get("ExpirationDate"):
        raise ValueError("provisioning profile expiration not available")
    from datetime import datetime, timezone
    expiration = profile_data["ExpirationDate"]
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        raise ValueError("provisioning profile has expired")

    for dylib in (converter, mirror):
        command("codesign", "--verify", "--strict", "--verbose=2", str(dylib))
        if team_id(dylib) != app_team:
            raise ValueError(f"dylib was signed with another team: {dylib}")

    print("PASS: native app code signature, provisioning and entitlements verified.")
    print("NOT VERIFIED: Windows guest process, first frame, audio, and device shutdown.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(args.app)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
