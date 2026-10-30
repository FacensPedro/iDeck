#!/usr/bin/env python3
"""Verify integrity of real signed-iPad evidence, not emulate Windows runtime PASS."""
import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

CHECKS = {
    "phase7": ("jit_attached", "jit_detached", "wine_rx_rw_wx"),
    "phase8": ("guest_first_launch", "wineserver_clean_exit", "guest_second_launch"),
    "phase9": ("guest_first_frame", "guest_subsequent_frames", "guest_audio",
               "touch_input", "controller_input"),
    "phase10": ("valid_signed_entitlements", "open_source_licenses", "signed_install"),
    "phase11": ("cold_start_after_reboot", "repeat_sessions", "release_test_report"),
}
OPTIONAL_CHECKS = {
    "wow64": ("wow64_i386_guest_launch", "wow64_guest_shutdown"),
    "d3d12": ("d3d12_guest_first_frame", "d3d12_shader_conversion"),
    "compatibility": ("vcruntime_imports", "dotnet_mono_runtime", "controller_hid_path"),
}
SHA_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
EVENTS = tuple(name for group in CHECKS.values() for name in group)
MAX_PROOF = 128 * 1024 * 1024


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def template(graphics: str, wow64: bool, compatibility: bool) -> dict:
    mandatory = list(EVENTS)
    if wow64:
        mandatory.extend(OPTIONAL_CHECKS["wow64"])
    if graphics == "d3d12":
        mandatory.extend(OPTIONAL_CHECKS["d3d12"])
    if compatibility:
        mandatory.extend(OPTIONAL_CHECKS["compatibility"])
    return {
        "schema": 1,
        "profile": {"graphics": graphics, "wow64": wow64, "compatibility": compatibility},
        "build": {"commit": "", "actions_run_url": "",
                  "unsigned_ipa_sha256": "", "signed_ipa_sha256": ""},
        "device": {"model": "", "ipad_os_build": "", "signing_team": ""},
        "signed_ipa": "",
        "corresponding_source_url": "",
        "checks": {name: {"status": "NOT RUN", "evidence_file": "", "sha256": ""}
                   for name in mandatory},
    }


def safe_file(base: Path, name: str) -> Path:
    if not name or Path(name).is_absolute():
        raise ValueError("evidence path must be a relative file")
    target = (base / name).resolve()
    if not target.is_relative_to(base.resolve()) or target.is_symlink() or not target.is_file():
        raise ValueError("evidence file must be a real file inside evidence root")
    return target


def validate(report: dict, base: Path) -> tuple[list[str], dict]:
    errors = []
    if report.get("schema") != 1:
        return ["unsupported device acceptance evidence schema"], {}
    profile = report.get("profile", {})
    if not isinstance(profile, dict) or profile.get("graphics") not in ("d3d11", "d3d12") or (
        type(profile.get("wow64")) is not bool or type(profile.get("compatibility")) is not bool
    ):
        return ["invalid exact graphics, WoW64 or compatibility profile"], {}
    expected = template(profile["graphics"], profile["wow64"], profile["compatibility"])
    build, device = report.get("build", {}), report.get("device", {})
    if not isinstance(build, dict) or not isinstance(device, dict):
        return ["build and device must be objects"], {}
    if not COMMIT_PATTERN.fullmatch(build.get("commit", "")):
        errors.append("missing exact commit SHA-1 for real IPA")
    url = build.get("actions_run_url", "")
    if not re.fullmatch(r"https://github\.com/FacensPedro/iDeck/actions/runs/[0-9]+", url):
        errors.append("missing provenance URL for the actual build")
    for field in ("unsigned_ipa_sha256", "signed_ipa_sha256"):
        value = build.get(field, "")
        if not isinstance(value, str) or not SHA_PATTERN.fullmatch(value):
            errors.append(f"missing verified {field} identifier")
    if not device.get("model") or not device.get("ipad_os_build"):
        errors.append("missing actual iPad model or iPadOS build")
    if not device.get("signing_team"):
        errors.append("missing actual signing team identifier")
    source = report.get("corresponding_source_url", "")
    if not isinstance(source, str) or not source.startswith("https://github.com/"):
        errors.append("public corresponding GPL/LGPL sources URL is missing")

    signed = report.get("signed_ipa", "")
    if not isinstance(signed, str):
        errors.append("signed_ipa must be a relative path")
    else:
        try:
            file = safe_file(base, signed)
            if not file.name.endswith(".ipa") or file.stat().st_size < 4096:
                errors.append("signed IPA is invalid or implausibly small")
            elif digest(file) != build.get("signed_ipa_sha256"):
                errors.append("signed IPA hash differs from the recorded device build")
        except (OSError, ValueError) as exc:
            errors.append(f"signed IPA evidence is unavailable: {exc}")

    checks = report.get("checks", {})
    if not isinstance(checks, dict):
        return errors + ["checks must be a dictionary"], {}
    expected_names = set(expected["checks"])
    if expected_names - set(checks):
        errors.append("missing required on-device test cases: " + ", ".join(sorted(expected_names - set(checks))))
    verified = {}
    for name in sorted(expected_names):
        test = checks.get(name)
        if not isinstance(test, dict):
            continue
        if test.get("status") != "PASS":
            errors.append(f"{name}: expected a real observed PASS, got {test.get('status')!r}")
            continue
        relative, sha = test.get("evidence_file", ""), test.get("sha256", "")
        if not isinstance(relative, str) or not isinstance(sha, str) or not SHA_PATTERN.fullmatch(sha):
            errors.append(f"{name}: missing evidence file or SHA-256")
            continue
        try:
            proof = safe_file(base, relative)
            if proof.stat().st_size < 128 or proof.stat().st_size > MAX_PROOF:
                errors.append(f"{name}: evidence file has invalid size")
                continue
            if digest(proof) != sha:
                errors.append(f"{name}: evidence file SHA-256 mismatch")
                continue
            if name in ("guest_first_frame", "guest_subsequent_frames", "d3d12_guest_first_frame"):
                with proof.open("rb") as stream:
                    first = stream.read(12)
                if not (first.startswith(b"\x89PNG\r\n\x1a\n")
                        or first.startswith(b"\xff\xd8\xff")
                        or first[4:8] == b"ftyp"):
                    errors.append(f"{name}: attach a PNG, JPEG or MP4 captured on the iPad")
                    continue
            verified[name] = {"sha256": sha, "bytes": proof.stat().st_size}
        except (OSError, ValueError) as exc:
            errors.append(f"{name}: no locally verifiable evidence: {exc}")
    receipt = {
        "schema": 1,
        "graphics": profile["graphics"],
        "wow64": profile["wow64"],
        "required": len(expected_names),
        "integrity_verified": len(verified),
        "evidence_hashes": verified,
        "ready_for_human_review": not errors,
        "device_compatibility_proven_automatically": False,
        "required_manual_review": [
            "The image is a guest-generated frame rather than the Wine splash screen",
            "Audio was heard and inputs controlled the actual Windows guest",
            "StikDebug BRK handling and protected RX/RW mappings actually worked",
            "Guest and wineserver exited cleanly and launched a second time",
            "Code signing, source licensing and redistributable ownership are correct",
        ],
    }
    return errors, receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--write-template", type=Path)
    parser.add_argument("--graphics", choices=("d3d11", "d3d12"), default="d3d11")
    parser.add_argument("--wow64", action="store_true")
    parser.add_argument("--compatibility", action="store_true")
    args = parser.parse_args()
    if args.write_template:
        args.write_template.parent.mkdir(parents=True, exist_ok=True)
        args.write_template.write_text(
            json.dumps(template(args.graphics, args.wow64, args.compatibility),
                       indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print("Created a NOT RUN device evidence template; no device claims were made.")
        return 0
    if not args.evidence:
        parser.error("--evidence or --write-template is required")
    try:
        report = json.loads(args.evidence.read_text(encoding="utf-8"))
        issues, receipt = validate(report, args.root)
    except (OSError, ValueError, TypeError, AttributeError, json.JSONDecodeError) as exc:
        print("ERROR: cannot validate device evidence: " + str(exc), file=sys.stderr)
        return 2
    if issues:
        for issue in issues:
            print("ERROR: " + issue, file=sys.stderr)
        return 2
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(f"Evidence integrity validated for {receipt['integrity_verified']} real files.")
    print("MANUAL REVIEW REQUIRED: no automated build or file hash proves real Windows gameplay.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
