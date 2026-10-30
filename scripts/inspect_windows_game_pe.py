#!/usr/bin/env python3
"""Inspect Windows PE architecture and DLL imports without executing or uploading the file."""
import argparse
import json
import struct
import sys
from pathlib import Path

MODULE_CAP = 256
IMAGE_CAP = 4 * 1024 * 1024 * 1024
SPECIAL = {
    "d3d11": {"d3d11.dll", "d3d10.dll", "d3d10core.dll"},
    "d3d12": {"d3d12.dll", "d3d12core.dll"},
    "directx_legacy": {"d3d9.dll", "d3d8.dll", "ddraw.dll"},
    "vulkan": {"vulkan-1.dll"},
    "visual_cpp_runtime": {"vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "msvcp140_1.dll", "msvcr120.dll"},
    "dotnet_framework": {"mscoree.dll"},
    "xinput": {"xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll"},
    "directinput": {"dinput8.dll"},
    "xaudio": {"xaudio2_7.dll", "xaudio2_9.dll"},
}


def inspect(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size < 256 or path.stat().st_size > IMAGE_CAP:
        raise ValueError("Windows PE missing or outside supported inspection limits")
    with path.open("rb") as source:
        dos = source.read(64)
        if dos[:2] != b"MZ":
            raise ValueError("not a Windows MZ executable")
        e_lfanew = struct.unpack_from("<I", dos, 0x3C)[0]
        if e_lfanew < 64 or e_lfanew > 64 * 1024 * 1024:
            raise ValueError("invalid PE header pointer")
        source.seek(e_lfanew)
        coff = source.read(24)
        if len(coff) != 24 or coff[:4] != b"PE\0\0":
            raise ValueError("invalid PE signature")
        machine, sections = struct.unpack_from("<HH", coff, 4)
        optional_size = struct.unpack_from("<H", coff, 20)[0]
        optional = source.read(optional_size)
        if len(optional) != optional_size or optional_size < 96 or sections < 1 or sections > 96:
            raise ValueError("invalid Windows optional header or sections")
        magic = struct.unpack_from("<H", optional)[0]
        if machine == 0x14C and magic == 0x10B:
            arch, data_dir = "x86", 96
        elif machine == 0x8664 and magic == 0x20B:
            arch, data_dir = "x86_64", 112
        else:
            raise ValueError(f"unsupported guest PE machine {machine:#06x} optional {magic:#06x}")
        section_table = source.read(sections * 40)
        if len(section_table) != sections * 40:
            raise ValueError("truncated PE section table")
        segments = []
        for index in range(sections):
            offset = index * 40
            virtual_size, rva, raw_size, raw_offset = struct.unpack_from("<IIII", section_table, offset + 8)
            segments.append((rva, max(virtual_size, raw_size), raw_size, raw_offset))

        def resolve(rva: int, size: int) -> int:
            for start, virtual_len, raw_len, file_start in segments:
                if rva >= start and rva - start + size <= min(virtual_len, raw_len):
                    offset = file_start + rva - start
                    if offset + size <= path.stat().st_size:
                        return offset
            raise ValueError("PE imported DLL name points outside mapped file sections")

        imports = []
        if optional_size >= data_dir + 16:
            directory_count = struct.unpack_from("<I", optional, data_dir - 4)[0]
            if directory_count > 1:
                import_rva, import_size = struct.unpack_from("<II", optional, data_dir + 8)
                if import_rva and import_size:
                    count = min(MODULE_CAP, import_size // 20)
                    for index in range(count):
                        source.seek(resolve(import_rva + index * 20, 20))
                        desc = source.read(20)
                        if desc == bytes(20):
                            break
                        name_rva = struct.unpack_from("<I", desc, 12)[0]
                        source.seek(resolve(name_rva, 1))
                        name = source.read(256).split(b"\0", 1)[0]
                        if not name or len(name) >= 256:
                            raise ValueError("invalid DLL import name")
                        imports.append(name.decode("ascii", errors="replace").lower())
    imports = sorted(set(imports))
    features = {feature: any(dll in group for dll in imports) for feature, group in SPECIAL.items()}
    return {
        "guest_architecture": arch,
        "requires_wow64": arch == "x86",
        "imports": imports,
        "possible_runtime_requirements": features,
        "graphics_profile_hint": "d3d12" if features["d3d12"] else "d3d11" if features["d3d11"] else "unknown",
        "may_use_dynamic_loadlibrary": True,
        "execution_verified": False,
        "explanation": "Static imports are hints, not proof that a game launches, renders or uses a specific API.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        report = inspect(args.executable)
    except (OSError, ValueError, struct.error) as exc:
        print("ERROR: Windows executable compatibility preflight: " + str(exc), file=sys.stderr)
        return 2
    data = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(data, encoding="utf-8")
    else:
        print(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
