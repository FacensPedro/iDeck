#!/usr/bin/env python3
"""Namespace proven private ntdll/wineserver Mach-O archive symbol collisions.

A Madeira native kit is verified against its checksums before extraction. This
operates on a *copy* of its extracted Wine server archive, never on the kit.
Only conflicts between Wine's ntdll Unix client/server.o and its separate
in-process wineserver registry/request objects are eligible. Other collisions
remain build failures, not silently suppressed linker diagnostics.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

from report_madeira_symbol_collisions import parse_defined_symbols

SERVER_MEMBERS = frozenset(("registry.o", "request_ios.o"))
PROTECTED_EXPORTS = frozenset((
    "_wineserver_main", "_wineserver_start", "_wineserver_is_ready",
    "_wine_process_start", "_wine_ui_log", "_wine_log_set_file",
    "_wineserver_set_nls_dir", "_wine_server_call",
))
OUT_NAME = "libwineserver_ideck_link.a"


class LinkArchiveError(RuntimeError):
    pass


def symbols_from_nm(output: str, archive: str) -> dict[str, set[str]]:
    symbols: dict[str, set[str]] = defaultdict(set)
    for symbol, location in parse_defined_symbols(output, archive):
        symbols[symbol].add(location)
    return dict(symbols)


def conflicts_to_namespace(ntdll: dict[str, set[str]],
                           server: dict[str, set[str]]) -> list[str]:
    selected = []
    for symbol in sorted(ntdll.keys() & server.keys()):
        left = {owner.rsplit("(", 1)[-1].removesuffix(")") for owner in ntdll[symbol]}
        right = {owner.rsplit("(", 1)[-1].removesuffix(")") for owner in server[symbol]}
        if left != {"server.o"} or not right or not right <= SERVER_MEMBERS:
            raise LinkArchiveError(
                f"unexpected ntdll/wineserver symbol collision {symbol}: "
                f"{sorted(ntdll[symbol])} versus {sorted(server[symbol])}"
            )
        if symbol in PROTECTED_EXPORTS:
            raise LinkArchiveError(f"cannot rename public Wine ABI symbol: {symbol}")
        selected.append(symbol)
    if len(selected) > 8:
        raise LinkArchiveError(f"unexpectedly many Wine symbol collisions: {len(selected)}")
    return selected


def run_nm(archive: Path) -> dict[str, set[str]]:
    command = ["xcrun", "--sdk", "iphoneos", "nm", "-gU", str(archive)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise LinkArchiveError(f"Mach-O nm failed for {archive.name}: {result.stderr.strip()}")
    return symbols_from_nm(result.stdout, archive.name)


def locate_objcopy() -> str:
    preferred = Path("vendor/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/llvm-objcopy")
    candidates = [
        os.environ.get("IDECK_LLVM_OBJCOPY"),
        str(preferred) if preferred.is_file() else None,
        shutil.which("llvm-objcopy"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise LinkArchiveError("llvm-objcopy is required to namespace Wine server archives")


def prepare(archives: Path) -> Path | None:
    ntdll_path = archives / "libntdll_unix.a"
    server_path = archives / "libwineserver.a"
    if not ntdll_path.is_file() or not server_path.is_file():
        raise LinkArchiveError("both compiled Wine archives must be present")
    destination = archives / OUT_NAME
    ntdll = run_nm(ntdll_path)
    server = run_nm(server_path)
    collisions = conflicts_to_namespace(ntdll, server)
    if not collisions:
        destination.unlink(missing_ok=True)
        print("Wine archive symbols: no ntdll/wineserver overlap")
        return None

    # Localize only the wineserver's *private* symbols. This renames all its
    # cross-object references as well, leaving the ntdll's external Wine API
    # unchanged. A new upstream archive must pass the member-ownership gate.
    remaps = [(name, "_ideck_ws_private_" + name.lstrip("_")) for name in collisions]
    if any(name in server for _, name in remaps):
        raise LinkArchiveError("namespaced Wine symbol already exists")
    with tempfile.TemporaryDirectory(prefix=".ideck-wine-link-", dir=archives) as directory:
        names = Path(directory) / "renames.txt"
        output = Path(directory) / OUT_NAME
        names.write_text("".join(f"{old} {new}\n" for old, new in remaps), encoding="utf-8")
        result = subprocess.run(
            [locate_objcopy(), "--redefine-syms", str(names), str(server_path), str(output)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode or not output.is_file():
            raise LinkArchiveError("cannot namespace Wine archive: " + result.stderr.strip())
        new_symbols = run_nm(output)
        if any(symbol in new_symbols for symbol in collisions):
            raise LinkArchiveError("Wine archive still exports a conflicting symbol")
        for _, renamed in remaps:
            if renamed not in new_symbols:
                raise LinkArchiveError(f"namespaced Wine symbol was lost: {renamed}")
        os.replace(output, destination)
    print(f"Namespaced {len(collisions)} private Wine server symbol(s) into {destination}")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archives", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.archives)
        return 0
    except (LinkArchiveError, OSError) as exc:
        print(f"ERROR: Madeira native Wine link preparation: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
