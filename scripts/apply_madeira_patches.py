#!/usr/bin/env python3
"""Apply one group of patches/series.txt to the pinned Madeira checkout.

Each patch is applied with `git apply` in its repository (the checkout itself or a
submodule). One that applies in reverse is already there and is skipped, so a
checkout can be prepared again; one that neither applies nor reverses means the
pinned sources moved, and the build stops naming the patch.

Every applied patch is recorded (name, SHA-256 and the repository's HEAD) in `ideck-applied-patches` inside
its repository's git directory. A recorded patch is skipped without any check, so a
second run on the same checkout works even when a later patch changed the same lines
(the reverse check of the earlier one would then fail).

    apply_madeira_patches.py <madeira checkout> <group>
"""
import hashlib
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


STAMP = "ideck-applied-patches"


def stamp_file(repo: Path):
    result = subprocess.run(["git", "-C", str(repo), "rev-parse", "--absolute-git-dir"],
                            capture_output=True, text=True)
    return Path(result.stdout.strip()) / STAMP if result.returncode == 0 else None


def recorded(repo: Path) -> set:
    stamp = stamp_file(repo)
    if stamp is None or not stamp.is_file():
        return set()
    return {line.strip() for line in stamp.read_text().splitlines() if line.strip()}


def record(repo: Path, entry: str) -> None:
    stamp = stamp_file(repo)
    if stamp is not None and entry not in recorded(repo):
        with stamp.open("a") as handle:
            handle.write(entry + "\n")


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
        head = subprocess.run(["git", "-C", str(target), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        entry = f"{name} {hashlib.sha256(patch.read_bytes()).hexdigest()} {head}"
        if entry in recorded(target):
            skipped += 1
            continue
        if git(target, "apply", "--reverse", "--check", str(patch)):
            record(target, entry)
            skipped += 1
            continue
        if not git(target, "apply", "--check", str(patch)):
            print(f"ERROR: {name} does not apply to the pinned sources in {repo}", file=sys.stderr)
            return 2
        if not git(target, "apply", str(patch)):
            print(f"ERROR: {name} failed while applying in {repo}", file=sys.stderr)
            return 2
        record(target, entry)
        applied += 1
    print(f"Patches [{group}]: {applied} applied, {skipped} already applied")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(apply_group(Path(sys.argv[1]), sys.argv[2]))
