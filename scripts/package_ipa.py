#!/usr/bin/env python3
"""Package iDeck.app as a directly downloadable IPA without copying the app tree."""

import argparse
import hashlib
import json
import os
import stat
import zipfile
from collections import defaultdict
from pathlib import Path

ALREADY_COMPRESSED = {
    ".7z", ".aifc", ".avif", ".car", ".gif", ".gz", ".heic", ".jpeg",
    ".jpg", ".m4a", ".mp3", ".mp4", ".png", ".webp", ".xz", ".zip", ".zst", ".zstd",
}


def audit_duplicate_files(app: Path) -> dict:
    """Report byte-identical files without deleting or linking required runtime paths."""
    sizes = defaultdict(list)
    scanned = 0
    for directory, _, files in os.walk(app, followlinks=False):
        for name in files:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            scanned += 1
            size = path.stat().st_size
            if size:
                sizes[size].append(path)
    duplicates = []
    for size, paths in sorted(sizes.items()):
        if len(paths) < 2:
            continue
        digests = defaultdict(list)
        for path in paths:
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1048576), b""):
                    digest.update(chunk)
            digests[digest.hexdigest()].append(path.relative_to(app).as_posix())
        for digest, names in sorted(digests.items()):
            if len(names) > 1:
                duplicates.append({"sha256": digest, "bytes_each": size,
                                   "paths": sorted(names),
                                   "potential_savings_bytes": size * (len(names) - 1)})
    return {"files_scanned": scanned, "duplicate_groups": duplicates,
            "potential_savings_bytes": sum(x["potential_savings_bytes"] for x in duplicates),
            "note": "Audit only: no files removed or hardlinked."}


def compression_settings(path: Path) -> dict:
    if path.suffix.lower() in ALREADY_COMPRESSED:
        return {"compress_type": zipfile.ZIP_STORED}
    if path.suffix.lower() in {".plist", ".json", ".xml", ".txt", ".strings",
                               ".html", ".css", ".md", ".csv"}:
        return {"compress_type": zipfile.ZIP_DEFLATED, "compresslevel": 9}
    return {"compress_type": zipfile.ZIP_DEFLATED, "compresslevel": 6}


def write_symlink(archive: zipfile.ZipFile, link: Path, name: str) -> None:
    metadata = link.lstat()
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = metadata.st_mode << 16
    info.compress_type = zipfile.ZIP_STORED
    archive.writestr(info, os.readlink(link).encode("utf-8"))


def build_ipa(app: Path, output: Path) -> None:
    app = app.absolute()
    output = output.absolute()
    if not app.is_dir() or not (app / "Info.plist").is_file():
        raise ValueError(f"Expected a compiled iDeck.app with Info.plist: {app}")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".part")
    root = "Payload/iDeck.app"

    try:
        with zipfile.ZipFile(
            temporary, "w", compression=zipfile.ZIP_DEFLATED,
            compresslevel=6, allowZip64=True,
        ) as archive:
            archive.writestr("Payload/", b"", compress_type=zipfile.ZIP_STORED)
            archive.write(app, root + "/")
            for directory, folders, files in os.walk(app, followlinks=False):
                folders.sort()
                files.sort()
                current = Path(directory)
                for name in list(folders):
                    path = current / name
                    relative = path.relative_to(app).as_posix()
                    target = root + "/" + relative
                    if path.is_symlink():
                        write_symlink(archive, path, target)
                        folders.remove(name)
                    else:
                        archive.write(path, target + "/",
                                      compress_type=zipfile.ZIP_STORED)
                for name in files:
                    path = current / name
                    relative = path.relative_to(app).as_posix()
                    target = root + "/" + relative
                    if path.is_symlink():
                        write_symlink(archive, path, target)
                    elif path.is_file():
                        archive.write(path, target, **compression_settings(path))
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duplicate-report", type=Path)
    args = parser.parse_args()
    if args.duplicate_report:
        report = audit_duplicate_files(args.app)
        args.duplicate_report.parent.mkdir(parents=True, exist_ok=True)
        args.duplicate_report.write_text(json.dumps(report, indent=2) + "\n")
        print("Duplicate audit: {} groups; {} potential bytes (no files removed)".format(
            len(report["duplicate_groups"]), report["potential_savings_bytes"]))
    build_ipa(args.app, args.output)
    print(f"Created {args.output} directly from {args.app}")


if __name__ == "__main__":
    main()
