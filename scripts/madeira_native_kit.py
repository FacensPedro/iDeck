#!/usr/bin/env python3
"""Build and consume a verified, relocatable iOS Madeira native runtime kit."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
REVISION = os.environ.get("IDECK_MADEIRA_REV", "fd9f2f3d0434a4116e4c3351f286a0fc376b4e36")
# Prebuilt kits must contain the compiled ARM64EC Mach slow-context fix.
# Hash the EXACT native overlay. A previous binary with the same upstream
# Madeira commit cannot be mistaken for a patched native runtime.
ARM64EC_CONTEXT_PATCH_SHA256 = hashlib.sha256(
    (Path(__file__).resolve().parents[1] /
     "patches/madeira-arm64ec-mach-context-return.patch").read_bytes()
).hexdigest()
ARCHIVES = (
    "libideck_madeira_upstream_bridges.a",
    "libFEXCore.a",
    "libFEXCore_Base.a",
    "libJemallocLibs.a",
    "libfmt.a",
    "libcephes_128bit.a",
    "libxxhash.a",
    "libsoftfloat_3e.a",
    "libwineserver.a",
    "libntdll_unix.a",
    "libwin32u_unix.a",
    "libdxmt_combined.a",
    "libgnutls.a",
    "libhogweed.a",
    "libnettle.a",
    "libgmp.a",
    "libavformat.a",
    "libavcodec.a",
    "libswresample.a",
    "libavutil.a",
)
FRAMEWORKS = (
    "Metal", "MetalFX", "QuartzCore", "AVFoundation", "AudioToolbox",
    "VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation", "IOKit",
    "ImageIO", "GameController", "CoreHaptics",
)
BASIC_FOLDERS = ("aarch64-windows", "arm64ec-windows", "nls", "d3d12", "legal", "licenses")
BASIC_FILES = ("prefix-template.tar.gz", "cacert.pem")
REQUIRED_PE = (
    "arm64ec-windows/xtajit64.dll", "arm64ec-windows/ntdll.dll",
    "arm64ec-windows/winemetal.dll", "arm64ec-windows/d3d11.dll",
    "arm64ec-windows/dxgi.dll", "arm64ec-windows/d3d12.dll",
    "arm64ec-windows/d3d12core.dll", "aarch64-windows/winemetal.dll",
    "arm64ec-windows/dcomp.dll",
    "arm64ec-windows/ktmw32.dll",
    "arm64ec-windows/faultrep.dll",
    "arm64ec-windows/xaudio2_7.dll",
    "arm64ec-windows/d3dx11_43.dll",
    "arm64ec-windows/d3dcompiler_47.dll",
    "arm64ec-windows/dinput8.dll",
)
WOW64_FILES = (
    "i386-windows/ntdll.dll", "i386-windows/kernel32.dll",
    "i386-windows/user32.dll", "i386-windows/d3d11.dll",
    "i386-windows/dxgi.dll", "aarch64-windows/xtajit.dll",
    "aarch64-windows/wow64.dll", "aarch64-windows/wow64win.dll",
)
MAX_FILE = 2 * 1024**3
MAX_TOTAL = 12 * 1024**3


class KitError(Exception):
    pass


def flavor(wow64: bool, mono: bool) -> str:
    return "-".join(v for v, enabled in (("wow64", wow64), ("mono", mono)) if enabled) or "base"


def default_path(wow64: bool, mono: bool, cache: bool) -> Path:
    folder = ROOT / ("build/native-cache" if cache else "runtime/prebuilt/ios-arm64")
    return folder / ("madeira-" + flavor(wow64, mono) + ".zip")


def digest_file(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def check_assets(app: Path, wow64: bool, mono: bool) -> None:
    for name in BASIC_FILES + REQUIRED_PE + (
        "nls/locale.nls", "d3d12/libmetalirconverter.dylib",
        "d3d12/canary_vs.dxil", "d3d12/canary_ps.dxil",
    ) + (WOW64_FILES if wow64 else ()) + (
        ("wine-mono/bin/libmono-2.0-x86.dll",) if mono else ()
    ):
        file = app / name
        if not file.is_file() or file.stat().st_size == 0:
            raise KitError("Missing native runtime resource: " + str(file))
    for name in REQUIRED_PE + (WOW64_FILES if wow64 else ()):
        with (app / name).open("rb") as stream:
            if stream.read(2) != b"MZ":
                raise KitError("Not a Windows PE image: " + name)
    if b"-----BEGIN CERTIFICATE-----" not in (app / "cacert.pem").read_bytes():
        raise KitError("Invalid bundled TLS trust roots")
    with (app / "prefix-template.tar.gz").open("rb") as stream:
        if stream.read(2) != b"\x1f\x8b":
            raise KitError("Invalid Wine prefix-template header")
    for name in BASIC_FOLDERS + (("i386-windows",) if wow64 else ()) + (
        ("wine-mono",) if mono else ()
    ):
        if not (app / name).is_dir():
            raise KitError("Missing runtime resource directory: " + name)


def archive_paths(madeira: Path, bridge: Path) -> dict[str, Path]:
    app = madeira / "app/Madeira"
    archives = {
        ARCHIVES[0]: bridge / ARCHIVES[0],
        ARCHIVES[1]: madeira / "FEX/build-ios/FEXCore/Source/libFEXCore.a",
        ARCHIVES[2]: madeira / "FEX/build-ios/FEXCore/Source/libFEXCore_Base.a",
        ARCHIVES[3]: madeira / "FEX/build-ios/FEXCore/Source/libJemallocLibs.a",
        ARCHIVES[4]: madeira / "FEX/build-ios/External/fmt/libfmt.a",
        ARCHIVES[5]: madeira / "FEX/build-ios/External/cephes/libcephes_128bit.a",
        ARCHIVES[6]: madeira / "FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a",
        ARCHIVES[7]: madeira / "FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a",
    }
    archives.update({name: app / name for name in ARCHIVES[8:]})
    return archives


def collect(madeira: Path, bridge: Path, wow64: bool, mono: bool,
            resource_root: Path | None = None) -> dict[str, Path]:
    app = resource_root or madeira / "app/Madeira"
    check_assets(app, wow64, mono)
    entries = {"archives/" + name: path for name, path in archive_paths(madeira, bridge).items()}
    for name in BASIC_FILES:
        entries["resources/" + name] = app / name
    folders = BASIC_FOLDERS + (("i386-windows",) if wow64 else ()) + (
        ("wine-mono",) if mono else ()
    )
    for name in folders:
        for file in (app / name).rglob("*"):
            if not file.is_file():
                continue
            # Madeira's resource folders contain empty Git directory
            # placeholders (notably i386-windows/.gitkeep). Required
            # runtime components are already validated by check_assets().
            if file.stat().st_size == 0 or file.name in (".gitkeep", ".DS_Store"):
                continue
            entries["resources/" + file.relative_to(app).as_posix()] = file
    for key, path in entries.items():
        if not path.is_file() or not path.stat().st_size:
            raise KitError("Missing compiled output: " + key + " → " + str(path))
        if path.stat().st_size > MAX_FILE:
            raise KitError("Oversized runtime output: " + key)
        if path.is_symlink():
            target = path.resolve(strict=True)
            roots = (madeira.resolve(), (resource_root or madeira / "app/Madeira").resolve(),
                     bridge.resolve())
            if not any(target.is_relative_to(root) for root in roots):
                raise KitError("External symlink in runtime output: " + str(path))
    return entries


def build_kit(output: Path, madeira: Path, bridge: Path, wow64: bool, mono: bool,
              resource_root: Path | None = None) -> None:
    rev = subprocess.check_output(["git", "-C", str(madeira), "rev-parse", "HEAD"], text=True).strip()
    if rev != REVISION:
        raise KitError(f"Madeira revision differs: expected {REVISION}, got {rev}")
    entries = collect(madeira, bridge, wow64, mono, resource_root)
    total = sum(path.stat().st_size for path in entries.values())
    if total > MAX_TOTAL:
        raise KitError("Native runtime exceeds the allowed kit size")
    hashes = {name: {"sha256": digest_file(path), "size": path.stat().st_size}
              for name, path in sorted(entries.items())}
    metadata = {"schema": 1, "madeira_revision": REVISION, "platform": "iphoneos-arm64",
                "wow64": wow64, "wine_mono": mono,
                "arm64ec_context_patch_sha256": ARM64EC_CONTEXT_PATCH_SHA256,
                "files": hashes}
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".zip.part")
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=5,
                             allowZip64=True) as bundle:
            bundle.writestr("metadata.json", json.dumps(metadata, sort_keys=True, indent=2) + "\n")
            for name, path in sorted(entries.items()):
                bundle.write(path, name)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print("Created native Madeira runtime kit:", output, f"({total:,} bytes uncompressed)")
    print("Store it using Git LFS only where redistribution is permitted.")


def validate_name(name: str) -> None:
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts or "\\" in name or name.startswith("./"):
        raise KitError("Unsafe kit entry: " + name)
    if name != str(path):
        raise KitError("Noncanonical kit path: " + name)


def inspect(archive: Path, wow64: bool, mono: bool):
    if not archive.is_file():
        raise KitError("Native kit not found: " + str(archive))
    try:
        bundle = zipfile.ZipFile(archive)
        names = bundle.namelist()
        if len(names) != len(set(names)) or not names or names[0] != "metadata.json":
            raise KitError("Invalid kit structure or duplicate entries")
        for item in bundle.infolist():
            validate_name(item.filename)
            if item.is_dir() or item.file_size > MAX_FILE:
                raise KitError("Invalid or oversized kit entry: " + item.filename)
            mode = (item.external_attr >> 16) & 0o170000
            if mode not in (0, 0o100000):
                raise KitError("Kit cannot contain symbolic links or special files")
        metadata = json.loads(bundle.read("metadata.json"))
        if metadata.get("schema") != 1 or metadata.get("madeira_revision") != REVISION or \
           metadata.get("platform") != "iphoneos-arm64" or \
           metadata.get("wow64") is not wow64 or metadata.get("wine_mono") is not mono:
            raise KitError("Kit revision/platform/options mismatch; compile a matching native kit")
        if metadata.get("arm64ec_context_patch_sha256") != ARM64EC_CONTEXT_PATCH_SHA256:
            raise KitError("ARM64EC Mach context patch mismatch; rebuild the Madeira native kit")
        files = metadata.get("files")
        if not isinstance(files, dict) or set(names) != set(files) | {"metadata.json"}:
            raise KitError("Kit file list differs from signed inventory")
        for name in ARCHIVES:
            if "archives/" + name not in files:
                raise KitError("Missing native ARM64 link archive: " + name)
        for name in BASIC_FILES + REQUIRED_PE + ("d3d12/libmetalirconverter.dylib",):
            if "resources/" + name not in files:
                raise KitError("Missing Windows payload: " + name)
        if wow64:
            for name in WOW64_FILES:
                if "resources/" + name not in files:
                    raise KitError("Kit contains incomplete WoW64 support: " + name)
        total = 0
        for name, info in files.items():
            validate_name(name)
            if not name.startswith(("archives/", "resources/")) or not isinstance(info, dict):
                raise KitError("Unexpected kit inventory path: " + name)
            size = info.get("size")
            sha = info.get("sha256")
            if type(size) is not int or size < 1 or size > MAX_FILE or \
               not isinstance(sha, str) or len(sha) != 64 or \
               not all(c in "0123456789abcdef" for c in sha):
                raise KitError("Invalid file checksum metadata: " + name)
            if bundle.getinfo(name).file_size != size:
                raise KitError("Inconsistent kit file size: " + name)
            total += size
            if total > MAX_TOTAL:
                raise KitError("Kit exceeds maximum extracted size")
        return bundle, metadata
    except Exception:
        if "bundle" in locals():
            bundle.close()
        raise


def link_flags(archive_root: Path) -> str:
    libs = [(archive_root / "archives" / name).resolve() for name in ARCHIVES]
    if any(not file.is_file() or not file.stat().st_size for file in libs):
        raise KitError("An expected native linker archive was not extracted")
    if any(" " in str(file) for file in libs):
        raise KitError("Native linker paths cannot contain spaces")
    flags = ["-lz", "-lc++", "-lsqlite3", "-llzma"]
    for name in FRAMEWORKS:
        flags.extend(("-framework", name))
    for index, file in enumerate(libs):
        if index in (0, 11):
            flags.extend(("-force_load", str(file)))
        else:
            flags.append(str(file))
    flags.extend(("-lcurses", "-lxml2"))
    return " ".join(flags) + "\n"


def install(archive: Path, output: Path, wow64: bool, mono: bool) -> None:
    bundle, metadata = inspect(archive, wow64, mono)
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=".madeira-kit-", dir=output.parent))
    try:
        for name, info in metadata["files"].items():
            target = temp / name
            target.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            with bundle.open(name) as src, target.open("wb") as dst:
                while data := src.read(1024 * 1024):
                    digest.update(data)
                    dst.write(data)
            if digest.hexdigest() != info["sha256"]:
                raise KitError("Runtime kit SHA-256 mismatch: " + name)
        check_assets(temp / "resources", wow64, mono)
        if output.exists():
            shutil.rmtree(output)
        temp.replace(output)
        temp = None
        out_flags = ROOT / "build/madeira-native/link-flags.txt"
        out_flags.parent.mkdir(parents=True, exist_ok=True)
        out_flags.write_text(link_flags(output), encoding="utf-8")
        print("Verified and staged prebuilt Madeira runtime:", archive)
    finally:
        bundle.close()
        if temp is not None:
            shutil.rmtree(temp, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("create", "install", "inspect", "path"))
    parser.add_argument("--wow64", action="store_true")
    parser.add_argument("--mono", action="store_true")
    parser.add_argument("--cache", action="store_true")
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "build/madeira-prebuilt")
    parser.add_argument("--madeira", type=Path, default=ROOT / "vendor/Madeira")
    parser.add_argument("--bridge", type=Path, default=ROOT / "build/madeira-native")
    parser.add_argument("--resource-root", type=Path)
    args = parser.parse_args()
    archive = args.archive or default_path(args.wow64, args.mono, args.cache)
    try:
        if args.action == "path":
            print(archive)
        elif args.action == "create":
            if os.environ.get("IDECK_ACCEPT_METAL_CONVERTER_LICENSE") != "1":
                raise KitError("Explicit Metal Shader Converter redistribution permission required")
            build_kit(archive, args.madeira, args.bridge, args.wow64, args.mono, args.resource_root)
        elif args.action == "inspect":
            bundle, _ = inspect(archive, args.wow64, args.mono)
            bundle.close()
            print("Matching Madeira native kit:", archive)
        else:
            if os.environ.get("IDECK_ACCEPT_METAL_CONVERTER_LICENSE") != "1":
                raise KitError("Explicit Metal Shader Converter redistribution permission required")
            install(archive, args.output, args.wow64, args.mono)
        return 0
    except (KitError, OSError, ValueError, KeyError, zipfile.BadZipFile,
            json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print("ERROR: Madeira native kit: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
