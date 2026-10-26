#!/usr/bin/env python3
"""Audit a built iOS .app before claiming that Madeira is integrated."""
import argparse
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path

SYMBOLS = (
    "ideck_madeira_launch_v1",
    "fex_initialize",
    "wineserver_start",
    "wineserver_is_ready",
    "wine_process_start",
    "wine_process_is_running",
    "madeira_seed_prefix_if_needed",
    "madeira_get_present_count",
    "madeira_d3d12_canary_run",
)
PE_FILES = (
    "aarch64-windows/d3d11.dll",
    "aarch64-windows/dxgi.dll",
    "aarch64-windows/winemetal.dll",
    "arm64ec-windows/ntdll.dll",
    "arm64ec-windows/d3d11.dll",
    "arm64ec-windows/dxgi.dll",
    "arm64ec-windows/d3d10core.dll",
    "arm64ec-windows/d3d12.dll",
    "arm64ec-windows/d3d12core.dll",
    "arm64ec-windows/xtajit64.dll",
    "arm64ec-windows/winemetal.dll",
)


def _read_at(stream, offset: int, length: int, file_size: int) -> bytes:
    if offset < 0 or length < 0 or offset + length > file_size:
        raise ValueError("PE field extends beyond the file")
    stream.seek(offset)
    result = stream.read(length)
    if len(result) != length:
        raise ValueError("truncated PE field")
    return result


def _pe_arch_error(dll: Path, require_arm64ec: bool) -> str | None:
    # A linked ARM64EC PE image legitimately uses IMAGE_FILE_MACHINE_AMD64
    # (0x8664). IMAGE_FILE_MACHINE_ARM64EC (0xA641) describes COFF objects,
    # not final executables. Verify the CHPE load-config metadata rather than
    # mistaking a plain x64 DLL for an ARM64EC one.
    # Microsoft: https://learn.microsoft.com/windows/arm/arm64ec
    import struct

    size = dll.stat().st_size
    try:
        with dll.open("rb") as stream:
            dos = _read_at(stream, 0, 64, size)
            if dos[:2] != b"MZ":
                return f"invalid PE DOS header: {dll}"
            pe_offset = struct.unpack_from("<I", dos, 0x3C)[0]
            if pe_offset < 64 or pe_offset > 64 * 1024 * 1024:
                return f"invalid PE DOS header: {dll}"
            signature = _read_at(stream, pe_offset, 24, size)
            if signature[:4] != b"PE\0\0":
                return f"invalid PE signature: {dll}"
            machine, sections = struct.unpack_from("<HH", signature, 4)
            optional_size = struct.unpack_from("<H", signature, 20)[0]
            if not 1 <= sections <= 96 or optional_size < 112:
                return f"invalid PE optional header: {dll}"
            optional = _read_at(stream, pe_offset + 24, optional_size, size)
            if struct.unpack_from("<H", optional)[0] != 0x20B:
                return f"not a 64-bit Windows PE image: {dll}"

            if not require_arm64ec:
                if machine != 0xAA64:
                    return f"unexpected PE machine {machine:#06x} for {dll}"
                return None

            if machine != 0x8664:
                return f"unexpected PE machine {machine:#06x} for {dll}"
            if optional_size < 200:
                return f"missing ARM64EC PE load configuration: {dll}"

            number_of_directories = struct.unpack_from("<I", optional, 108)[0]
            if number_of_directories <= 10:
                return f"missing ARM64EC PE load configuration: {dll}"
            load_rva, load_size = struct.unpack_from("<II", optional, 192)
            if not load_rva or load_size < 208:
                return f"missing ARM64EC CHPE metadata: {dll}"

            image_base = struct.unpack_from("<Q", optional, 24)[0]
            size_of_headers = struct.unpack_from("<I", optional, 60)[0]
            section_data = _read_at(stream, pe_offset + 24 + optional_size,
                                    sections * 40, size)
            section_table = []
            for index in range(sections):
                pos = index * 40
                virtual_size, va, raw_size, raw_offset = struct.unpack_from(
                    "<IIII", section_data, pos + 8
                )
                section_table.append((va, max(virtual_size, raw_size),
                                      raw_size, raw_offset))

            def file_offset(rva: int, count: int) -> int:
                if rva >= 0 and rva + count <= size_of_headers:
                    return rva
                for va, mapped_size, raw_size, raw_offset in section_table:
                    if va <= rva and rva - va + count <= min(raw_size, mapped_size):
                        return raw_offset + (rva - va)
                raise ValueError("RVA is not backed by a PE file section")

            config_offset = file_offset(load_rva, 208)
            load_config = _read_at(stream, config_offset, 208, size)
            declared_size = struct.unpack_from("<I", load_config)[0]
            if declared_size < 208 or load_size < 208:
                return f"missing ARM64EC CHPE metadata: {dll}"
            chpe_va = struct.unpack_from("<Q", load_config, 200)[0]
            if chpe_va < image_base:
                return f"missing ARM64EC CHPE metadata: {dll}"
            chpe_rva = chpe_va - image_base
            metadata = _read_at(stream, file_offset(chpe_rva, 4), 4, size)
            version = struct.unpack("<I", metadata)[0]
            if not 1 <= version <= 4:
                return f"invalid ARM64EC CHPE metadata version {version} for {dll}"
            return None
    except (OSError, ValueError, struct.error) as exc:
        return f"invalid ARM64EC PE structure for {dll}: {exc}"


def inspect(app: Path) -> list[str]:
    errors = []
    executable = app / "iDeck"
    if not executable.is_file():
        return [f"missing app executable: {executable}"]
    # Modern Xcode Debug builds may place actual app/native code in
    # iDeck.debug.dylib, leaving iDeck as a tiny executor stub. Inspect both.
    native_images = [executable]
    debug_dylib = app / "iDeck.debug.dylib"
    if debug_dylib.exists():
        native_images.append(debug_dylib)
    exported = set()
    for image in native_images:
        try:
            result = subprocess.run(
                ["xcrun", "nm", "-arch", "arm64", "-gU", str(image)],
                check=True, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )
            exported.update(re.findall(
                r"(?m)^.*\s_([A-Za-z][A-Za-z0-9_]*)\s*$", result.stdout
            ))
        except (OSError, subprocess.CalledProcessError) as exc:
            errors.append(f"unable to inspect linked arm64 symbols in {image}: {exc}")
    errors.extend(
        f"native symbol not linked/exported: {name}"
        for name in SYMBOLS if name not in exported
    )

    runtime = app / "MadeiraRuntime"
    for path in PE_FILES:
        dll = runtime / path
        if not dll.is_file() or dll.stat().st_size < 1024:
            errors.append(f"missing compiled Windows PE library: {dll}")
            continue
        problem = _pe_arch_error(dll, path.startswith("arm64ec-windows/"))
        if problem:
            errors.append(problem)
    converter = runtime / "d3d12" / "libmetalirconverter.dylib"
    if not converter.is_file() or converter.stat().st_size < 1024:
        errors.append(f"missing or empty iOS shader converter dependency: {converter}")

    prefix = app / "prefix-template.tar.gz"
    if not prefix.is_file() or prefix.stat().st_size < 1024:
        errors.append(f"missing Madeira Wine prefix template: {prefix}")
    else:
        with prefix.open("rb") as stream:
            if stream.read(2) != bytes((0x1f, 0x8b)):
                errors.append(f"invalid Wine prefix gzip signature: {prefix}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--require", action="store_true",
                        help="fail if native runtime is absent; never produce a false-ready IPA")
    options = parser.parse_args()
    app = options.app
    manifest = app / "MadeiraRuntimeManifest.plist"
    if manifest.exists():
        manifest.unlink()

    errors = inspect(app)
    if errors:
        for error in errors:
            print(f"Madeira check: {error}", file=sys.stderr)
        if options.require:
            print("Native runtime build FAILED verification.", file=sys.stderr)
            return 1
        print("Packaging interface-only IPA. Windows execution remains disabled.")
        return 0

    with manifest.open("wb") as handle:
        plistlib.dump({
            "runtimeABI": 1,
            "fexInProcess": True,
            "wineInProcess": True,
            "dxmtLinked": True,
            "d3d12Linked": True,
        }, handle)
    print("Native payload and symbols found. Device integration testing is still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
