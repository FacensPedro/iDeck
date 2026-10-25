#!/usr/bin/env python3
"""Report potentially conflicting strong Mach-O symbols in native archives.

A static archive member is linked only if selected by the linker, so this is
diagnostic output and deliberately does not fail on potential collisions.
"""
import argparse
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

OBJECT_HEADER = re.compile(r"^(?P<file>.+\.a)\((?P<member>[^)]+)\):\s*$")
INLINE_SYMBOL = re.compile(
    r"^(?P<location>.+\.a\([^)]+\)):\s*"
    r"(?P<value>[0-9A-Fa-f]+)\s+(?P<type>[A-Z])\s+(?P<symbol>\S+)\s*$"
)
SYMBOL = re.compile(r"^[0-9A-Fa-f]+\s+([A-Z])\s+(\S+)\s*$")
STRONG = frozenset("TBDSCG")


def parse_defined_symbols(output: str, archive: str):
    current = archive
    for line in output.splitlines():
        entry = OBJECT_HEADER.match(line)
        if entry:
            current = f"{Path(entry.group('file')).name}({entry.group('member')})"
            continue
        inline = INLINE_SYMBOL.match(line)
        if inline:
            if inline.group("type") in STRONG:
                yield inline.group("symbol"), Path(inline.group("location")).name
            continue
        symbol = SYMBOL.match(line.strip())
        if symbol and symbol.group(1) in STRONG:
            yield symbol.group(2), current


def collisions_from_outputs(outputs):
    owners = defaultdict(set)
    for name, content in outputs.items():
        for symbol, owner in parse_defined_symbols(content, name):
            owners[symbol].add(owner)
    return {symbol: sorted(items) for symbol, items in owners.items() if len(items) > 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", nargs="+", type=Path)
    parser.add_argument("--limit", type=int, default=50)
    args = parser.parse_args()
    sources = {}
    for archive in args.archives:
        result = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "nm", "-gU", str(archive)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            print(f"WARNING: cannot inspect {archive}: {result.stderr.strip()}", file=sys.stderr)
            continue
        sources[archive.name] = result.stdout
    conflicts = collisions_from_outputs(sources)
    print(f"Potential strong native symbol overlaps: {len(conflicts)}")
    for symbol, owners in sorted(conflicts.items())[:max(0, args.limit)]:
        print(f"  {symbol}: {', '.join(owners)}")
    if len(conflicts) > max(0, args.limit):
        print(f"  ... {len(conflicts) - args.limit} additional overlaps")
    print("Only linker-selected archive members create actual duplicate definitions.")


if __name__ == "__main__":
    main()
