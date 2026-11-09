#!/usr/bin/env python3
"""Move Wine's Windows files out of iDeck.app into downloads for the initial setup.

The IPA keeps the signed iOS code, the iOS dylibs (gl/, d3d12/), the prefix
template and the manifests.  The PE farms become two content-addressed .tar.xz
archives, published as assets of a GitHub release tagged runtime-<hash>:

  wine-x64: aarch64-windows, arm64ec-windows, nls, compat, vulkan
  wine-x86: i386-windows (WoW64)

Wine Mono and the Microsoft Visual C++ runtimes are left out of the IPA too: the
initial setup downloads them from WineHQ and Microsoft (WineMono.swift,
VisualCRuntimeBootstrap.swift).  iDeckRuntimeDownloads.plist in the app lists each
archive's URL, SHA-256 and size (MadeiraRuntime.swift); <out>/runtime-release.json
names the tag and files for the publishing step.  Run after the bundle verifiers
and the profile stamp, before packaging.
"""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import sys
import tarfile
from pathlib import Path

PACKAGES = (
    ("wine-x64", "x64 Wine environment", ("aarch64-windows", "arm64ec-windows", "nls", "compat", "vulkan")),
    ("wine-x86", "x86 (WoW64) environment", ("i386-windows",)),
)
DROPPED = ("wine-mono", "vcruntime-bundle", "x86_64-vcruntime")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    info.mode = 0o755 if info.isdir() else 0o644
    return info


def archive(app: Path, folders, target: Path) -> int:
    files = 0
    with tarfile.open(target, "w:xz", preset=6, dereference=True, format=tarfile.GNU_FORMAT) as tar:
        for folder in folders:
            base = app / folder
            for root, dirs, names in os.walk(base, followlinks=True):
                dirs.sort()
                rel_root = Path(root).relative_to(app)
                tar.add(root, arcname=str(rel_root), recursive=False, filter=normalized)
                for name in sorted(names):
                    tar.add(Path(root) / name, arcname=str(rel_root / name), filter=normalized)
                    files += 1
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY") or "FacensPedro/iDeck")
    args = parser.parse_args()
    app, out = args.app, args.out
    if not (app / "arm64ec-windows/ntdll.dll").is_file():
        print("ERROR: no staged Windows runtime to split", file=sys.stderr)
        return 2
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    built = []
    for ident, title, folders in PACKAGES:
        present = [f for f in folders if (app / f).is_dir()]
        if not present:
            continue
        staging = out / f"{ident}.tar.xz"
        count = archive(app, present, staging)
        digest = sha256(staging)
        name = f"{ident}-{digest[:16]}.tar.xz"
        staging.rename(out / name)
        built.append({"id": ident, "title": title, "file": name, "sha256": digest,
                      "bytes": (out / name).stat().st_size, "folders": present, "files": count})
        print(f"{ident}: {count} files, {(out / name).stat().st_size} bytes, sha256 {digest}")
    if not built or built[0]["id"] != "wine-x64":
        print("ERROR: the x64 runtime archive was not built", file=sys.stderr)
        return 2

    tag = "runtime-" + hashlib.sha256("".join(p["sha256"] for p in built).encode()).hexdigest()[:16]
    base = f"https://github.com/{args.repo}/releases/download/{tag}/"
    manifest = {"schema": 1, "tag": tag, "packages": [
        {"id": p["id"], "title": p["title"], "url": base + p["file"], "sha256": p["sha256"], "bytes": p["bytes"]}
        for p in built]}
    with (app / "iDeckRuntimeDownloads.plist").open("wb") as handle:
        plistlib.dump(manifest, handle, sort_keys=True)
    (out / "runtime-release.json").write_text(json.dumps({"tag": tag, "repo": args.repo, "packages": built}, indent=2))

    for ident, _, folders in PACKAGES:
        for folder in folders:
            shutil.rmtree(app / folder, ignore_errors=True)
    for folder in DROPPED:
        shutil.rmtree(app / folder, ignore_errors=True)
    print(f"Windows runtime moved to downloads ({tag}); Wine Mono and Visual C++ are fetched by the initial setup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
