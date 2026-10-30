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
    info = app / "Info.plist"
    manifest = app / "MadeiraRuntimeManifest.plist"
    profile = app / "embedded.mobileprovision"
    converter = app / "d3d12/libmetalirconverter.dylib"
    mirror = app / "MadeiraRuntime/d3d12/libmetalirconverter.dylib"
    for file in (binary, info, manifest, profile):
        if not file.is_file() or not file.stat().st_size:
            raise ValueError(f"missing signed native app input: {file}")

    with info.open("rb") as stream:
        bundle_id = plistlib.load(stream).get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise ValueError("signed app has no CFBundleIdentifier")

    with manifest.open("rb") as stream:
        metadata = plistlib.load(stream)
    for key in ("fexInProcess", "wineInProcess", "dxmtLinked"):
        if metadata.get(key) is not True:
            raise ValueError(f"native bundle manifest does not prove {key}")
    backend = metadata.get("graphicsBackend")
    if backend not in ("d3d11", "d3d12") or metadata.get("d3d12Linked") is not (backend == "d3d12"):
        raise ValueError("native bundle graphics profile is incomplete or dishonest")
    if backend == "d3d12":
        for file in (converter, mirror):
            if not file.is_file() or not file.stat().st_size:
                raise ValueError(f"missing signed native app input: {file}")
    elif any(p.name == "libmetalirconverter.dylib" for p in app.rglob("*")):
        raise ValueError("D3D11 signed IPA contains proprietary Metal Shader Converter")
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
    allowed_id = authorized.get("application-identifier")
    exact_id = f"{app_team}.{bundle_id}"
    if allowed_id not in (exact_id, f"{app_team}.*"):
        raise ValueError(f"provisioning profile does not authorize app ID: {bundle_id}")
    signed_id = signed.get("application-identifier")
    if signed_id != exact_id:
        raise ValueError(f"signature does not identify the expected app ID: {bundle_id}")
    if not profile_data.get("ExpirationDate"):
        raise ValueError("provisioning profile expiration not available")
    from datetime import datetime, timezone
    expiration = profile_data["ExpirationDate"]
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        raise ValueError("provisioning profile has expired")

    if backend == "d3d12":
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
