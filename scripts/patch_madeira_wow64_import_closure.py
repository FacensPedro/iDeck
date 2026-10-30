#!/usr/bin/env python3
"""Apply a narrow, reproducible import-closure fix to pinned public Madeira."""
import argparse
from pathlib import Path

ORIGINAL = '        echo "$present" | grep -qx "$l" && continue'
PATCHED = '        grep -Fxq -- "$l" <<< "$present" && continue'


def patch(madeira: Path) -> bool:
    script = madeira / "build/wine-i386/build.sh"
    content = script.read_text(encoding="utf-8")
    old_count = content.count(ORIGINAL)
    new_count = content.count(PATCHED)
    if old_count == 1 and new_count == 0:
        script.write_text(content.replace(ORIGINAL, PATCHED), encoding="utf-8")
        return True
    if old_count == 0 and new_count == 1:
        return False
    raise ValueError("Unexpected pinned Madeira WoW64 import-checker source; refusing ambiguous changes")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--madeira", type=Path, required=True)
    args = parser.parse_args()
    changed = patch(args.madeira)
    print(("Patched" if changed else "Verified") + " Madeira WoW64 import checker without SIGPIPE")


if __name__ == "__main__":
    main()
