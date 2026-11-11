#!/usr/bin/env python3
"""Ship every Wine NLS table, not only the en-US ones.

Madeira's app/Madeira/nls holds locale.nls, the sort and normalization tables and
four code pages (437, 1252, 20127, 28591): what an en-US Windows needs.  ntdll takes
the Windows locale from the device (build/ntdll-unix/env_ios.c, init_locale), so a
device set to any other language asks for code pages that are not there: OEM 850
for Portuguese, Spanish, French or German, 932 for Japanese, 866 and 1251 for
Russian.  NtGetNlsSectionPtr then fails, and cmd.exe, console programs, installers
and games that convert text in the OEM or ANSI code page break.

The pinned Wine tree carries all the tables prebuilt (wine/nls/*.nls).  Copy the
ones Madeira leaves out next to its own; Madeira's own files are kept as they are.
"""
import shutil
import sys
from pathlib import Path

# A table of each kind that only the full set has: checked by the kit and the staging.
REQUIRED = ("c_850.nls", "c_932.nls", "c_1251.nls", "c_10000.nls")


def main(root: str) -> int:
    base = Path(root)
    source = base / "wine/nls"
    target = base / "app/Madeira/nls"
    if not (target / "locale.nls").is_file():
        print(f"ERROR: Madeira's NLS folder is missing: {target}", file=sys.stderr)
        return 2
    tables = sorted(source.glob("*.nls"))
    if not tables:
        print(f"ERROR: the Wine tree has no NLS tables: {source}", file=sys.stderr)
        return 2
    added = 0
    for table in tables:
        destination = target / table.name
        if destination.is_file() and destination.stat().st_size:
            continue
        if not table.stat().st_size:
            print(f"ERROR: empty NLS table in the Wine tree: {table}", file=sys.stderr)
            return 2
        shutil.copyfile(table, destination)
        added += 1
    missing = [name for name in REQUIRED if not (target / name).is_file()]
    if missing:
        print("ERROR: NLS tables still missing: " + ", ".join(missing), file=sys.stderr)
        return 2
    total = len(list(target.glob("*.nls")))
    print(f"NLS: {added} Wine tables added, {total} in the runtime")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
