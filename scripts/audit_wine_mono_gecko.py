#!/usr/bin/env python3
"""Read-only Wine Mono/Gecko inventory across iDeck app and Wine prefixes."""
import argparse
import hashlib
import json
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1048576), b""):
            value.update(block)
    return value.hexdigest()


def audit(app: Path, support: Path, prefixes: list[Path]) -> dict:
    candidates = []
    bundled = app / "wine-mono"
    downloaded = support / "WineMono" / "wine-mono"
    for label, path in (("bundled", bundled), ("downloaded", downloaded)):
        marker = path / "bin/libmono-2.0-x86.dll"
        if marker.is_file() and not marker.is_symlink():
            candidates.append({"component": "mono", "location": label,
                               "path": str(path), "sha256": digest(marker)})
    for prefix in prefixes:
        cache = prefix / ".cache/wine"
        for arch in ("x86", "x86_64"):
            file = cache / f"wine-gecko-2.47.4-{arch}.msi"
            if file.is_file() and not file.is_symlink():
                candidates.append({"component": "gecko", "arch": arch,
                                   "path": str(file), "bytes": file.stat().st_size,
                                   "sha256": digest(file)})
    groups = {}
    for item in candidates:
        groups.setdefault((item["component"], item.get("arch", "all"), item["sha256"]), []).append(item["path"])
    repeated = [paths for paths in groups.values() if len(paths) > 1]
    return {"components": candidates, "identical_copies": repeated,
            "note": "Read-only report; does not delete, link, or modify Wine files."}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--support", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, action="append", default=[])
    args = parser.parse_args()
    print(json.dumps(audit(args.app, args.support, args.prefix), indent=2))


if __name__ == "__main__":
    main()
