#!/usr/bin/env python3
"""Audit original Windows guest probe logs; never certify a physical iPad run."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

MAX_LOG = 4 * 1024 * 1024
SMOKE = re.compile(r"^ideck-guest-smoke=1 arch=(32|64) pid=([1-9][0-9]*)$", re.M)
PRESENT11 = re.compile(r"^ideck-d3d11-frame-probe: presents=(\d+) hr=0x([0-9a-fA-F]+)$", re.M)
PRESENT12 = re.compile(r"^ideck-d3d12-frame-probe: presents=(\d+) hr=0x([0-9a-fA-F]+) exit=(\d+)$", re.M)
AUDIO_FIELDS = (
    "waveout_submitted", "waveout_completed", "xinput_connected",
    "xinput_button_event", "touch_event",
)


def read_log(root: Path, relative: str) -> tuple[Path, str]:
    path = Path(relative)
    if not relative or path.is_absolute() or ".." in path.parts:
        raise ValueError("guest log path must remain under the evidence directory")
    candidate = root
    for part in path.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise ValueError("guest log path must not contain symlinks")
    real_root = root.resolve()
    resolved = candidate.resolve()
    if not resolved.is_relative_to(real_root) or not resolved.is_file():
        raise ValueError("missing regular guest log")
    size = resolved.stat().st_size
    if size < 16 or size > MAX_LOG:
        raise ValueError("guest log outside permitted byte-size range")
    return resolved, resolved.read_text(encoding="utf-8", errors="strict")


def parse_smoke(contents: str, bits: int) -> int:
    matches = SMOKE.findall(contents)
    if len(matches) != 1 or int(matches[0][0]) != bits:
        raise ValueError(f"expected one real PE{bits} Windows guest smoke receipt")
    return int(matches[0][1])


def parse_audio(contents: str, bits: int) -> dict:
    fields = {}
    for line in contents.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in fields:
            raise ValueError(f"duplicate audio probe field: {key}")
        fields[key] = value.strip()
    if fields.get("ideck_guest_probe") != "audio-input-v1" or fields.get("guest_arch") != str(bits):
        raise ValueError(f"wrong PE{bits} guest audio/input probe")
    if not fields.get("pid", "").isdigit() or int(fields["pid"]) == 0:
        raise ValueError("guest audio/input receipt has no real PID")
    for key in AUDIO_FIELDS:
        if fields.get(key) != "1":
            raise ValueError(f"guest {bits}-bit audio/input probe failed {key}")
    return {"guest_arch": bits, "pid": int(fields["pid"]), **{key: True for key in AUDIO_FIELDS}}


def parse_frame(contents: str, api: str) -> dict:
    match = (PRESENT12 if api == "d3d12" else PRESENT11).search(contents)
    frames = 120 if api == "d3d12" else 180
    if not match or int(match.group(1)) != frames or int(match.group(2), 16) != 0:
        raise ValueError(f"guest {api} test did not report {frames} successful presents")
    if api == "d3d12" and int(match.group(3)) != 0:
        raise ValueError("guest D3D12 frame probe did not exit successfully")
    return {"api": api, "presents": frames, "guest_submission_reported": True}


def audit(root: Path, paths: dict[str, str]) -> dict:
    findings = {}
    hashes = {}
    for key, relative in paths.items():
        file, contents = read_log(root, relative)
        hashes[key] = {"sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
                       "bytes": file.stat().st_size, "file": relative}
        if key.startswith("smoke_"):
            bits = 32 if "x86" in key else 64
            findings[key] = {"pid": parse_smoke(contents, bits), "arch": bits}
        elif key.startswith("audio_"):
            findings[key] = parse_audio(contents, 32 if key.endswith("x86") else 64)
        else:
            findings[key] = parse_frame(contents, "d3d12" if key.startswith("d3d12") else "d3d11")
    for arch in ("x86", "x64"):
        first = findings[f"smoke_{arch}_first"]["pid"]
        second = findings[f"smoke_{arch}_second"]["pid"]
        if first == second:
            raise ValueError(f"guest {arch} first and second launch use the same PID")
        if hashes[f"smoke_{arch}_first"]["sha256"] == hashes[f"smoke_{arch}_second"]["sha256"]:
            raise ValueError(f"guest {arch} first and second launch duplicate the same receipt")
    return {
        "schema": 1,
        "device_execution_verified_automatically": False,
        "human_review_required": True,
        "logs_passing_format_and_reported_result_checks": len(findings),
        "findings": findings,
        "evidence": hashes,
        "remaining_manual_checks": [
            "Confirm traces originate from the signed IPA running on the physical iPad",
            "Confirm guest-generated changing D3D11/D3D12 pixels in an iPad recording",
            "Confirm PCM test tone is actually audible from the Windows guest",
            "Confirm a real game controller and iPad touch generated the recorded events",
            "Confirm Wine/wineserver exit, JIT permissions and reboot/relaunch stability",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    for name in ("smoke_x86_first", "smoke_x86_second", "smoke_x64_first",
                 "smoke_x64_second", "audio_x86", "audio_x64",
                 "d3d11_x86", "d3d11_x64"):
        parser.add_argument("--" + name.replace("_", "-"), required=True)
    parser.add_argument("--d3d12-x64")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    names = ("smoke_x86_first", "smoke_x86_second", "smoke_x64_first",
             "smoke_x64_second", "audio_x86", "audio_x64",
             "d3d11_x86", "d3d11_x64", "d3d12_x64")
    paths = {name: getattr(args, name) for name in names if getattr(args, name, None)}
    try:
        receipt = audit(args.root, paths)
    except (ValueError, OSError, UnicodeError) as exc:
        print(f"ERROR: guest probe receipt rejected: {exc}", file=sys.stderr)
        return 2
    output = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    else:
        print(output)
    print("Probe log checks passed; this is NOT proof of physical iPad execution.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
