#!/usr/bin/env python3
"""Extract only the licensed iOS Metal Shader Converter dylib and license from an owner-supplied Apple PKG."""
import argparse
import bz2
import gzip
import hashlib
import io
import json
import os
import shutil
import struct
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

PACKAGE_SHA256 = "449833211e4ef0d46bfaa94848e801acff49e226d3c348bba0673f13716be622"
IOS_LIBRARY = "./usr/local/lib_iOS/libmetalirconverter.dylib"
LICENSE_RESOURCE = ("Resources", "English.lproj", "License.rtf")
LIBRARY_NAME = "libmetalirconverter.dylib"
LICENSE_NAME = "METAL-SHADER-CONVERTER-4.0-BETA-3-LICENSE.rtf"
PROVENANCE_NAME = "apple-msc-4.0-beta-3-provenance.json"
HEADER_PREFIX = "./usr/local/include/"
HEADER_FAMILIES = ("metal_irconverter/", "metal_irconverter_runtime/", "metal_irconverter_ext/")
REQUIRED_HEADERS = (
    "metal_irconverter/metal_irconverter.h",
    "metal_irconverter_runtime/metal_irconverter_runtime.h",
    "metal_irconverter_runtime/ir_tessellator_tables.h",
    "metal_irconverter_ext/Metal_HLSL.inc",
)


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def open_pkg(path: Path):
    with path.open("rb") as source:
        header = source.read(28)
        if len(header) != 28:
            raise ValueError("truncated XAR package header")
        magic, header_size, version, compressed, unpacked, algorithm = struct.unpack(">4sHHQQI", header)
        if magic != b"xar!" or version != 1 or header_size < 28 or compressed > 8_000_000 or unpacked > 32_000_000:
            raise ValueError("not a supported Apple Metal Shader Converter XAR package")
        source.seek(header_size)
        data = zlib.decompress(source.read(compressed))
        if len(data) != unpacked:
            raise ValueError("invalid XAR table-of-contents length")
        tree = ET.fromstring(data)
        return tree.find("toc"), header_size + compressed


def member(toc, names):
    current = toc
    for name in names:
        matches = [entry for entry in current.findall("file") if entry.findtext("name") == name]
        if len(matches) != 1:
            raise ValueError("package does not have required path: " + "/".join(names))
        current = matches[0]
    data = current.find("data")
    if data is None:
        raise ValueError("missing package member data: " + "/".join(names))
    return data


def read_member(pkg: Path, toc, start: int, names: tuple[str, ...]) -> bytes:
    data = member(toc, names)
    off, length = int(data.findtext("offset")), int(data.findtext("length"))
    if off < 0 or length > 1_000_000:
        raise ValueError("unexpected license resource size")
    with pkg.open("rb") as source:
        source.seek(start + off)
        result = source.read(length)
    if data.find("encoding").get("style") == "application/x-bzip2":
        result = bz2.decompress(result)
    if not result or len(result) > 1_000_000:
        raise ValueError("unreadable license resource")
    return result


class Window(io.RawIOBase):
    def __init__(self, source, length: int):
        self.source, self.remaining = source, length

    def readable(self):
        return True

    def readinto(self, buffer):
        data = self.source.read(min(len(buffer), self.remaining))
        self.remaining -= len(data)
        buffer[:len(data)] = data
        return len(data)


def copy_exact(source, target, length: int):
    remaining = length
    while remaining:
        data = source.read(min(1024 * 1024, remaining))
        if not data:
            raise ValueError("truncated gzip CPIO member")
        if target is not None:
            target.write(data)
        remaining -= len(data)


def extract_ios_library(pkg: Path, toc, start: int, destination: Path, headers: Path | None = None):
    payload = member(toc, ("MetalShaderConverter.pkg", "Payload"))
    off, length = int(payload.findtext("offset")), int(payload.findtext("length"))
    if length > 100_000_000 or off < 0:
        raise ValueError("unexpected compressed package payload")
    found = False
    extracted_headers = set()
    with pkg.open("rb") as raw:
        raw.seek(start + off)
        with gzip.GzipFile(fileobj=io.BufferedReader(Window(raw, length))) as stream:
            for _ in range(256):
                header = stream.read(76)
                if not header:
                    break
                if len(header) != 76 or header[:6] != b"070707":
                    raise ValueError("unsupported Apple installer CPIO format")
                name_length = int(header[59:65], 8)
                data_length = int(header[65:76], 8)
                if name_length < 1 or name_length > 4096 or data_length > 120_000_000:
                    raise ValueError("invalid CPIO archive member")
                name = stream.read(name_length).rstrip(b"\0").decode("utf-8")
                if name == "TRAILER!!!":
                    break
                if name == IOS_LIBRARY:
                    if found or data_length < 10_000_000:
                        raise ValueError("invalid or duplicate iOS converter library")
                    with destination.open("wb") as out:
                        copy_exact(stream, out, data_length)
                    found = True
                elif headers is not None and name.startswith(HEADER_PREFIX):
                    relative = name[len(HEADER_PREFIX):]
                    if (
                        relative in REQUIRED_HEADERS or
                        any(relative.startswith(group) for group in HEADER_FAMILIES)
                    ):
                        from pathlib import PurePosixPath
                        parts = PurePosixPath(relative).parts
                        if (
                            ".." in parts or len(parts) != 2 or
                            not relative.endswith((".h", ".inc", ".txt")) or
                            data_length > 4_000_000
                        ):
                            raise ValueError("unsafe or unsupported converter SDK header: " + name)
                        target = headers.joinpath(*parts)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        with target.open("wb") as output:
                            copy_exact(stream, output, data_length)
                        extracted_headers.add(relative)
                    else:
                        copy_exact(stream, None, data_length)
                else:
                    copy_exact(stream, None, data_length)
    if not found:
        raise ValueError("Apple iOS ARM64 converter library missing from package")
    if headers is not None and not set(REQUIRED_HEADERS).issubset(extracted_headers):
        raise ValueError("Apple package is missing required 4.0 beta 3 converter SDK headers")


def ios_macho_details(path: Path) -> dict:
    with path.open("rb") as source:
        header = source.read(32)
        if len(header) != 32 or struct.unpack_from("<I", header)[0] != 0xFEEDFACF:
            raise ValueError("iOS library is not a thin 64-bit Mach-O binary")
        _, cpu, subcpu, filetype, commands, command_bytes, _, _ = struct.unpack("<IiiIIIII", header)
        if cpu != 0x0100000C or filetype != 6 or commands > 128 or command_bytes > 65536:
            raise ValueError("converter is not an ARM64 Mach-O dynamic library")
        data = source.read(command_bytes)
    offset, build = 0, None
    for _ in range(commands):
        if offset + 8 > len(data):
            raise ValueError("truncated Mach-O load commands")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("invalid Mach-O load command")
        if command == 0x32:
            if size < 24:
                raise ValueError("invalid LC_BUILD_VERSION")
            _, _, platform, minimum, sdk, _ = struct.unpack_from("<IIIIII", data, offset)
            if platform != 2:
                raise ValueError("Metal converter library is not built for iOS")
            decode = lambda number: f"{number >> 16}.{(number >> 8) & 0xff}.{number & 0xff}"
            build = {"platform": "iOS", "minimum_ios": decode(minimum), "sdk": decode(sdk)}
        offset += size
    if build is None:
        raise ValueError("iOS Metal converter is missing LC_BUILD_VERSION")
    return build


def prepare(pkg: Path, destination: Path, acknowledge_license: bool,
            headers_destination: Path | None = None) -> dict:
    if not acknowledge_license:
        raise ValueError("read Apple's embedded License.rtf and explicitly pass --acknowledge-license")
    if not pkg.is_file():
        raise ValueError("Apple installer package does not exist")
    actual = digest(pkg)
    if actual != PACKAGE_SHA256:
        raise ValueError("package SHA-256 differs from the audited 4.0 beta 3 upload")
    toc, start = open_pkg(pkg)
    if toc is None:
        raise ValueError("package has no file listing")
    license_bytes = read_member(pkg, toc, start, LICENSE_RESOURCE)
    if b"SOFTWARE LICENSE AGREEMENT" not in license_bytes or b"METAL" not in license_bytes:
        raise ValueError("Apple license is absent or unreadable")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ideck-msc-") as temporary:
        library = Path(temporary) / LIBRARY_NAME
        headers = Path(temporary) / "include" if headers_destination is not None else None
        extract_ios_library(pkg, toc, start, library, headers)
        details = ios_macho_details(library)
        result = {
            "converter": "Apple Metal Shader Converter 4.0 beta 3",
            "package_sha256": actual,
            "library_sha256": digest(library),
            "library_bytes": library.stat().st_size,
            "license_sha256": hashlib.sha256(license_bytes).hexdigest(),
            "headers_sha256": {
                file.relative_to(headers).as_posix(): digest(file)
                for file in sorted(headers.rglob("*")) if file.is_file()
            } if headers is not None else {},
            "architecture": "arm64",
            **details,
            "runtime_shader_conversion": True,
            "device_execution_verified": False,
        }
        tmp_license = Path(temporary) / LICENSE_NAME
        tmp_license.write_bytes(license_bytes)
        tmp_receipt = Path(temporary) / PROVENANCE_NAME
        tmp_receipt.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        shutil.copyfile(library, destination / LIBRARY_NAME)
        shutil.copyfile(tmp_license, destination / LICENSE_NAME)
        shutil.copyfile(tmp_receipt, destination / PROVENANCE_NAME)
        if headers is not None:
            headers_destination.mkdir(parents=True, exist_ok=True)
            for file in headers.rglob("*"):
                if not file.is_file():
                    continue
                target = headers_destination / file.relative_to(headers)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(file, target)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pkg", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--headers-destination", type=Path, required=True)
    parser.add_argument("--acknowledge-license", action="store_true")
    args = parser.parse_args()
    try:
        receipt = prepare(args.pkg, args.destination, args.acknowledge_license,
                          args.headers_destination)
    except (OSError, ValueError, OverflowError, EOFError, gzip.BadGzipFile) as exc:
        print("ERROR: Metal Shader Converter package preparation failed: " + str(exc), file=sys.stderr)
        return 2
    print(json.dumps(receipt, indent=2, sort_keys=True))
    print("Owner-supplied Apple files were prepared locally and were NOT uploaded to GitHub.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
