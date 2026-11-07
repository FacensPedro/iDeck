#!/usr/bin/env python3
"""Fetch a pinned Optima source snapshot for the iOS port (not a runtime build).

This intentionally does not stage Optima's Linux CLI or Windows DLLs into the IPA.
The upstream CLI must first be refactored into a Rust staticlib with a C ABI and
an iOS-compatible browser authentication flow.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import pathlib
import tarfile
import urllib.request

UPSTREAM = "Starkka15/Optima"
REVISION = "bb92444e58f3c984a83f1b1fa9b2f6eb582471a6"
URL = f"https://api.github.com/repos/{UPSTREAM}/tarball/{REVISION}"
MAX_ARCHIVE_BYTES = 12 * 1024 * 1024
SOURCE_ROOT = pathlib.Path("vendor/Optima")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=pathlib.Path, default=SOURCE_ROOT)
    args = parser.parse_args()
    request = urllib.request.Request(URL, headers={"User-Agent": "iDeck-Optima-source-bootstrap"})
    with urllib.request.urlopen(request, timeout=45) as response:
        data = response.read(MAX_ARCHIVE_BYTES + 1)
    if len(data) > MAX_ARCHIVE_BYTES:
        raise SystemExit("Optima source archive exceeded size limit")
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    count = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive:
            if not member.isfile():
                continue
            parts = pathlib.PurePosixPath(member.name).parts[1:]
            if not parts or any(p in ("..", ".") for p in parts):
                continue
            # Source only: never vendor prebuilt DLLs or local auth files.
            if pathlib.PurePosixPath(*parts).suffix.lower() in (".dll", ".exe", ".cer", ".crt"):
                continue
            target = (destination / pathlib.Path(*parts)).resolve()
            if not target.is_relative_to(destination):
                raise SystemExit("Unsafe archive entry")
            target.parent.mkdir(parents=True, exist_ok=True)
            stream = archive.extractfile(member)
            if stream is None:
                continue
            target.write_bytes(stream.read())
            count += 1
    print(f"Optima source snapshot {REVISION}: {count} files staged at {destination}")
    print(f"Archive SHA-256: {hashlib.sha256(data).hexdigest()}")
    print("NOTE: Source only; Optima is not compiled or integrated into the iDeck IPA.")


if __name__ == "__main__":
    main()
