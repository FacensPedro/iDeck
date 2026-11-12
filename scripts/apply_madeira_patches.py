#!/usr/bin/env python3
"""Apply one group of patches/series.txt to the pinned Madeira checkout.

Each patch is applied with `git apply` in its repository (the checkout itself or a
submodule). One that applies in reverse is already there and is skipped, so a
checkout can be prepared again; one that neither applies nor reverses means the
pinned sources moved, and the build stops naming the patch.

    apply_madeira_patches.py <madeira checkout> <group>
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERIES = ROOT / "patches/series.txt"


def series(path: Path = SERIES):
    entries = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3:
            raise ValueError(f"{path.name}:{number}: expected group, repository, patch")
        entries.append(tuple(parts))
    return entries


def git(repo: Path, *args: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True).returncode == 0


def apply_group(madeira: Path, group: str, path: Path = SERIES, patches: Path = None) -> int:
    patches = patches or path.parent
    selected = [(repo, name) for g, repo, name in series(path) if g == group]
    if not selected:
        print(f"ERROR: no patches in group {group!r}", file=sys.stderr)
        return 2
    applied = skipped = 0
    for repo, name in selected:
        patch = patches / name
        target = madeira / repo
        if not patch.is_file():
            print(f"ERROR: {name} is listed but missing", file=sys.stderr)
            return 2
        if git(target, "apply", "--reverse", "--check", str(patch)):
            skipped += 1
            continue
        if not git(target, "apply", "--check", str(patch)):
            print(f"ERROR: {name} does not apply to the pinned sources in {repo}", file=sys.stderr)
            return 2
        if not git(target, "apply", str(patch)):
            print(f"ERROR: {name} failed while applying in {repo}", file=sys.stderr)
            return 2
        applied += 1
    print(f"Patches [{group}]: {applied} applied, {skipped} already applied")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(apply_group(Path(sys.argv[1]), sys.argv[2]))
