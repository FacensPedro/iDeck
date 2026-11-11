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
import concurrent.futures
import hashlib
import io
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
# Madeira's own bring-up and test programs. Every farm file is linked into each
# prefix's system32, and no game, installer or iDeck code starts these.
TEST_PROGRAMS = (
    "arm64ec-windows/calltest-x64.exe", "arm64ec-windows/child-test-x64.exe",
    "arm64ec-windows/clocktest-x64.exe", "arm64ec-windows/cube-x64.exe",
    "arm64ec-windows/d3d12-cube-x64.exe", "arm64ec-windows/d3d12-m2-x64.exe",
    "arm64ec-windows/d3d12-vfetch-x64.exe", "arm64ec-windows/dxchkmsaa-x64.exe",
    "arm64ec-windows/fib-x64.exe", "arm64ec-windows/fib2-x64.exe", "arm64ec-windows/fib3-x64.exe",
    "arm64ec-windows/fileio-x64.exe", "arm64ec-windows/fpconf-x64.exe",
    "arm64ec-windows/heap-x64.exe", "arm64ec-windows/hello-x64.exe",
    "arm64ec-windows/proc-test-x64.exe",
    "aarch64-windows/child-test.exe", "aarch64-windows/cube.exe", "aarch64-windows/proc-test.exe",
    "aarch64-windows/texquad.exe", "aarch64-windows/triangle.exe", "aarch64-windows/winhttp-test.exe",
)


# The Windows machine each farm holds. arm64ec-windows is ARM64EC, which a PE header
# declares as x64 (0x8664); a DLL of another architecture in a farm fails to load
# with STATUS_INVALID_IMAGE_FORMAT at the first program that imports it.
MACHINES = {
    "aarch64-windows": (0xAA64,),
    "arm64ec-windows": (0x8664, 0xA641),
    "i386-windows": (0x014C,),
    "vulkan": (0x8664, 0xA641),
    "compat": (0x8664,),
}


def pe_machine(path: Path):
    """The COFF machine of a PE image, or None for any other file."""
    with path.open("rb") as handle:
        head = handle.read(0x40)
        if len(head) < 0x40 or head[:2] != b"MZ":
            return None
        handle.seek(int.from_bytes(head[0x3C:0x40], "little"))
        signature = handle.read(6)
    if len(signature) < 6 or signature[:4] != b"PE\0\0":
        return None
    return int.from_bytes(signature[4:6], "little")


def wrong_architecture(app: Path, folders) -> list:
    wrong = []
    for folder in folders:
        allowed = MACHINES.get(folder)
        if not allowed:
            continue
        for path in sorted((app / folder).rglob("*")):
            if path.is_file():
                machine = pe_machine(path)
                if machine is not None and machine not in allowed:
                    wrong.append(f"{path.relative_to(app)} (machine 0x{machine:04x})")
    return wrong


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


def archive(app: Path, folders, target: Path, ident: str) -> int:
    """The folders plus ideck-runtime-<id>.json (relative path -> SHA-256 of every
    file), which the app checks each unpacked file against (MadeiraRuntime.validate)."""
    files = 0
    hashes = {}
    for folder in folders:
        for root, dirs, names in os.walk(app / folder, followlinks=True):
            for name in names:
                path = Path(root) / name
                hashes[str(path.relative_to(app))] = sha256(path)
    manifest = json.dumps(hashes, sort_keys=True, indent=0).encode()
    with tarfile.open(target, "w:xz", preset=6, dereference=True, format=tarfile.GNU_FORMAT) as tar:
        info = normalized(tarfile.TarInfo(f"ideck-runtime-{ident}.json"))
        info.size = len(manifest)
        tar.addfile(info, io.BytesIO(manifest))
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

    removed = 0
    for name in TEST_PROGRAMS:
        program = app / name
        if program.is_file():
            program.unlink()
            removed += 1
    print(f"Test programs left out of the runtime: {removed}")

    jobs = []
    for ident, title, folders in PACKAGES:
        present = [f for f in folders if (app / f).is_dir()]
        if not present:
            continue
        wrong = wrong_architecture(app, present)
        if wrong:
            print(f"ERROR: {ident} holds images of another architecture: " + ", ".join(wrong[:20]), file=sys.stderr)
            return 2
        jobs.append((ident, title, present, out / f"{ident}.tar.xz"))

    # xz is single-threaded and the archives are independent: one process each, so
    # the x86 farm compresses while the x64 one does. The bytes are the same as
    # compressing them one after the other.
    with concurrent.futures.ProcessPoolExecutor(max_workers=len(jobs) or 1) as pool:
        counts = list(pool.map(archive, [app] * len(jobs), [j[2] for j in jobs],
                               [j[3] for j in jobs], [j[0] for j in jobs]))

    built = []
    for (ident, title, present, staging), count in zip(jobs, counts):
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
