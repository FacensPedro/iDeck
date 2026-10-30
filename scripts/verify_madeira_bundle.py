#!/usr/bin/env python3
"""Audit a built iOS .app before claiming that Madeira is integrated."""
import argparse
import hashlib
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
    "wine_process_thread_finished",
    "wine_process_exit_code",
    "wine_crash_exit_status",
    "wineserver_is_running",
    "winios_post_key",
    "winios_gamepad_set_state",
    "winios_hidpad_set_state",
    "madeira_pad_output_configure",
    "madeira_pad_output_set_slot",
    "madeira_display_set_layer",
    "macdrv_functions",
    "winios_screen_size",
    "winios_display_mode_changed",
    "madeira_seed_prefix_if_needed",
    "madeira_get_present_count",
    "madeira_d3d12_canary_run",
    "madeira_luajit_compat_fd",
)
D3D12_SYMBOLS = ("madeira_d3d12_canary_run",)
D3D12_PE_FILES = (
    "arm64ec-windows/madeira_d3d12.dll",
    "arm64ec-windows/d3d12.dll",
    "arm64ec-windows/d3d12core.dll",
)
D3D12_PROHIBITED = D3D12_PE_FILES + (
    "aarch64-windows/madeira_d3d12.dll",
    "aarch64-windows/d3d12.dll",
    "aarch64-windows/d3d12core.dll",
    "d3d12/libmetalirconverter.dylib",
)
PE_FILES = (
    "aarch64-windows/d3d11.dll",
    "aarch64-windows/dxgi.dll",
    "aarch64-windows/winemetal.dll",
    "aarch64-windows/kernel32.dll",
    "aarch64-windows/user32.dll",
    "arm64ec-windows/ntdll.dll",
    "arm64ec-windows/kernel32.dll",
    "arm64ec-windows/kernelbase.dll",
    "arm64ec-windows/user32.dll",
    "arm64ec-windows/gdi32.dll",
    "arm64ec-windows/ws2_32.dll",
    "arm64ec-windows/d3d9.dll",
    "arm64ec-windows/vulkan-1.dll",
    "arm64ec-windows/madeira_d3d12.dll",
    "arm64ec-windows/d3d11.dll",
    "arm64ec-windows/dxgi.dll",
    "arm64ec-windows/d3d10core.dll",
    "arm64ec-windows/d3d12.dll",
    "arm64ec-windows/d3d12core.dll",
    "arm64ec-windows/xtajit64.dll",
    "arm64ec-windows/winemetal.dll",
    "arm64ec-windows/dcomp.dll",
    "arm64ec-windows/ktmw32.dll",
    "arm64ec-windows/faultrep.dll",
    "arm64ec-windows/xaudio2_7.dll",
    "arm64ec-windows/d3dx11_43.dll",
    "arm64ec-windows/d3dcompiler_47.dll",
    "arm64ec-windows/dinput8.dll",
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


def _pe32_error(dll: Path) -> str | None:
    try:
        with dll.open("rb") as stream:
            data = stream.read(64)
            if len(data) != 64 or data[:2] != b"MZ":
                return f"invalid WoW64 DOS header: {dll}"
            offset = struct.unpack_from("<I", data, 0x3C)[0]
            if offset < 64 or offset > 64 * 1024 * 1024:
                return f"invalid WoW64 PE offset: {dll}"
            stream.seek(offset)
            header = stream.read(26)
            if len(header) != 26 or header[:4] != b"PE\0\0":
                return f"invalid WoW64 PE header: {dll}"
            machine = struct.unpack_from("<H", header, 4)[0]
            magic = struct.unpack_from("<H", header, 24)[0]
            if machine != 0x014C or magic != 0x010B:
                return f"WoW64 module must be i386 PE32: {dll}"
    except OSError as exc:
        return f"unreadable WoW64 module {dll}: {exc}"
    return None


def inspect(app: Path, require_wow64: bool = False, graphics: str = "d3d12") -> list[str]:
    if graphics not in ("d3d11", "d3d12"):
        raise ValueError(f"invalid Madeira graphics profile: {graphics}")
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
    required_symbols = SYMBOLS if graphics == "d3d12" else tuple(
        name for name in SYMBOLS if name not in D3D12_SYMBOLS
    )
    errors.extend(
        f"native symbol not linked/exported: {name}"
        for name in required_symbols if name not in exported
    )

    runtime = app / "MadeiraRuntime"
    required_pe = PE_FILES if graphics == "d3d12" else tuple(
        name for name in PE_FILES if name not in D3D12_PE_FILES
    )
    for path in required_pe:
        for directory in (app, runtime):
            dll = directory / path
            if not dll.is_file() or dll.stat().st_size < 1024:
                errors.append(f"missing compiled Windows PE library: {dll}")
                continue
            problem = _pe_arch_error(dll, path.startswith("arm64ec-windows/"))
            if problem:
                errors.append(problem)
    for directory in (app, runtime) if graphics == "d3d12" else ():
        native = directory / "arm64ec-windows/madeira_d3d12.dll"
        loader = directory / "arm64ec-windows/d3d12.dll"
        if native.is_file() and loader.is_file():
            def digest(path: Path) -> bytes:
                sha = hashlib.sha256()
                with path.open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        sha.update(block)
                return sha.digest()
            if digest(native) != digest(loader):
                errors.append(f"D3D12 loader differs from Madeira native frontend: {loader}")
    for directory in (app, runtime):
        lua = directory / "compat" / "love" / "lua51.dll"
        if not lua.is_file() or lua.stat().st_size < 1024:
            errors.append(f"missing GC64 LuaJIT x64 compatibility DLL: {lua}")
        elif lua.read_bytes()[:2] != b"MZ":
            errors.append(f"invalid GC64 LuaJIT PE image: {lua}")
    license_file = app / "licenses" / "LuaJIT-MIT.txt"
    if not license_file.is_file() or not license_file.stat().st_size:
        errors.append(f"missing LuaJIT license notice: {license_file}")
    for directory in (app, runtime):
        locale = directory / "nls" / "locale.nls"
        if not locale.is_file() or locale.stat().st_size == 0:
            errors.append(f"missing Wine locale resource: {locale}")
    wow64 = require_wow64 or (app / "i386-windows/ntdll.dll").is_file()
    if wow64:
        for directory in (app, runtime):
            for name in ("ntdll.dll", "kernel32.dll", "user32.dll",
                         "d3d11.dll", "dxgi.dll"):
                dll = directory / "i386-windows" / name
                if not dll.is_file() or dll.stat().st_size < 1024:
                    errors.append(f"missing WoW64 i386 library: {dll}")
                else:
                    problem = _pe32_error(dll)
                    if problem:
                        errors.append(problem)
        for name in ("aarch64-windows/xtajit.dll",
                     "aarch64-windows/wow64.dll",
                     "aarch64-windows/wow64win.dll"):
            for directory in (app, runtime):
                dll = directory / name
                if not dll.is_file() or dll.stat().st_size < 1024:
                    errors.append(f"missing WoW64 native host DLL: {dll}")
                else:
                    problem = _pe_arch_error(dll, False)
                    if problem:
                        errors.append(problem)

    ca = app / "cacert.pem"
    if not ca.is_file() or b"-----BEGIN CERTIFICATE-----" not in ca.read_bytes():
        errors.append(f"missing Madeira HTTPS certificate bundle: {ca}")
    for folder in ("legal", "licenses"):
        if not (app / folder).is_dir():
            errors.append(f"missing Madeira license directory: {app / folder}")
    for directory in (app, runtime) if graphics == "d3d12" else ():
        for name in ("canary_vs.dxil", "canary_ps.dxil",
                     "canary_layout_vs.dxil", "canary_layout_ps.dxil"):
            fixture = directory / "d3d12" / name
            if not fixture.is_file() or fixture.stat().st_size == 0:
                errors.append(f"missing D3D12 canary fixture: {fixture}")
        converter = directory / "d3d12" / "libmetalirconverter.dylib"
        if not converter.is_file() or converter.stat().st_size < 1024:
            errors.append(f"missing or empty iOS shader converter dependency: {converter}")

    if graphics == "d3d11":
        for directory in (app, runtime):
            for name in D3D12_PROHIBITED:
                asset = directory / name
                if asset.exists() or asset.is_symlink():
                    errors.append(f"D3D11 profile must not bundle D3D12 or Apple converter: {asset}")
            if (directory / "d3d12").exists() or (directory / "d3d12").is_symlink():
                errors.append(f"D3D11 profile contains a D3D12 payload directory: {directory / 'd3d12'}")
        for item in app.rglob("libmetalirconverter.dylib"):
            errors.append(f"D3D11 profile must not redistribute the Apple converter: {item}")
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
    parser.add_argument("--app", type=Path)
    parser.add_argument("--linker-flags", action="store_true",
                        help="retain and export required native entry points")
    parser.add_argument("--graphics", choices=("d3d11", "d3d12"), default="d3d12",
                        help="strict native graphics profile; d3d11 forbids D3D12 and Apple converter")
    parser.add_argument("--require", action="store_true",
                        help="fail if native runtime is absent; never produce a false-ready IPA")
    parser.add_argument("--require-wow64", action="store_true",
                        help="require a complete i386/ARM64 WoW64 payload")
    options = parser.parse_args()
    if options.linker_flags:
        symbols = SYMBOLS if options.graphics == "d3d12" else tuple(
            name for name in SYMBOLS if name not in D3D12_SYMBOLS
        )
        print("-Wl,-export_dynamic " + " ".join(f"-Wl,-u,_{name}" for name in symbols))
        return 0
    if options.app is None:
        parser.error("--app is required unless --linker-flags is used")
    app = options.app
    manifest = app / "MadeiraRuntimeManifest.plist"
    if manifest.exists():
        manifest.unlink()

    errors = inspect(app, require_wow64=options.require_wow64, graphics=options.graphics)
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
            "d3d12Linked": options.graphics == "d3d12",
            "graphicsBackend": options.graphics,
            "wow64Enabled": (app / "i386-windows/ntdll.dll").is_file(),
        }, handle)
    print("Native payload and symbols found. Device integration testing is still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
