#!/usr/bin/env python3
"""Audit shipped iOS IPA scripts and emit independent SHA-256 distribution receipts.

This is a supply-chain integrity check, NOT an antivirus scanner or a
determination that a binary is free of malware. Never bypass an AV detection.
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

SOURCE_ROOT = Path(__file__).resolve().parents[1]
ROOT = "Payload/iDeck.app/"
# .jitscript: StikDebug's JavaScript, shipped under its own extension. It is
# iOS debugger data, never a Windows script, and a .js name made Windows
# Defender's machine-learning model flag the downloaded IPA
# (Trojan:Script/Wacatac.B!ml, a generic false positive).
SCRIPT_EXTENSIONS = {".jitscript", ".js", ".jse", ".vbs", ".vbe", ".wsf", ".wsh", ".ps1", ".psm1",
                     ".bat", ".cmd", ".hta"}
EXPECTED_JIT = {
    ROOT + "universal.jitscript": "scripts/jit/universal.jitscript",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def hash_file(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def safe_member(name):
    if (not name.startswith(ROOT) and name != "Payload/" and name != "Payload/iDeck.app/"):
        return False
    if "\\" in name or "\x00" in name or name.startswith("/"):
        return False
    parts = PurePosixPath(name).parts
    return bool(parts) and all(part not in (".", "..") for part in parts) and not any(
        part == ".." for part in name.split("/")
    )


def inspect_ipa(path, source_root=SOURCE_ROOT):
    if not zipfile.is_zipfile(path):
        raise ValueError("Not a valid IPA/ZIP archive")
    names = set()
    scripts = []
    verified = []
    with zipfile.ZipFile(path) as ipa:
        for entry in ipa.infolist():
            if not safe_member(entry.filename):
                raise ValueError("Unsafe or unexpected IPA archive entry: " + entry.filename)
            if entry.filename in names:
                raise ValueError("Duplicate IPA archive entry: " + entry.filename)
            names.add(entry.filename)
            if entry.is_dir():
                continue
            suffix = PurePosixPath(entry.filename).suffix.lower()
            if suffix not in SCRIPT_EXTENSIONS:
                continue
            if entry.file_size > 16 * 1024 * 1024:
                raise ValueError("Unexpectedly large embedded script: " + entry.filename)
            data = ipa.read(entry)
            record = {
                "path": entry.filename,
                "bytes": entry.file_size,
                "sha256": digest(data),
                "review": "not-in-source-JIT-allowlist",
            }
            source = EXPECTED_JIT.get(entry.filename)
            if source is not None:
                expected = source_root / source
                if not expected.is_file() or digest(data) != hash_file(expected):
                    raise ValueError("Bundled JIT script differs from reviewed source: " + entry.filename)
                record["review"] = "matches-repository-source"
                record["source"] = source
                verified.append(entry.filename)
            scripts.append(record)
        if ROOT + "Info.plist" not in names:
            raise ValueError("IPA is missing its app Info.plist")
        if ROOT + "universal.jitscript" not in verified:
            raise ValueError("IPA is missing the verified StikDebug universal.jitscript required for Madeira JIT")
    return {
        "schema_version": 1,
        "product": "iDeck for iOS/iPadOS",
        "archive_file": path.name,
        "archive_bytes": path.stat().st_size,
        "archive_sha256": hash_file(path),
        "source_commit": os.environ.get("GITHUB_SHA", "unavailable"),
        "security_verdict": "NOT_SCANNED; hashes and packaging alone do not establish malware safety",
        "verified_jit_scripts": sorted(verified),
        "embedded_script_inventory": sorted(scripts, key=lambda x: x["path"]),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--sha256-file", type=Path, required=True)
    args = parser.parse_args(argv)
    result = inspect_ipa(args.ipa)
    for output in (args.json, args.sha256_file):
        output.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.sha256_file.write_text(f"{result['archive_sha256']}  {args.ipa.name}\n", encoding="ascii")
    print("IPA archive SHA-256:", result["archive_sha256"])
    print("Embedded scripts reviewed:", len(result["verified_jit_scripts"]))
    print("Embedded script inventory:", len(result["embedded_script_inventory"]))
    print("Security verdict: unknown — submit a specific Defender detection to Microsoft")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print("ERROR: IPA distribution audit failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
