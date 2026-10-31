#!/usr/bin/env python3
"""Package iDeck.app as a directly downloadable IPA without copying the app tree."""

import argparse
import os
import stat
import zipfile
from pathlib import Path

ALREADY_COMPRESSED = {
    ".7z", ".aifc", ".avif", ".car", ".gif", ".gz", ".heic", ".jpeg",
    ".jpg", ".m4a", ".mp3", ".mp4", ".png", ".webp", ".xz", ".zip",
}


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
                        compression = (zipfile.ZIP_STORED if
                                       path.suffix.lower() in ALREADY_COMPRESSED else
                                       zipfile.ZIP_DEFLATED)
                        archive.write(path, target, compress_type=compression)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build_ipa(args.app, args.output)
    print(f"Created {args.output} directly from {args.app}")


if __name__ == "__main__":
    main()
