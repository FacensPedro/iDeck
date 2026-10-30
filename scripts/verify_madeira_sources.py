#!/usr/bin/env python3
"""Verify exact public Madeira submodule pins after a recursive checkout."""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REVISION = "fd9f2f3d0434a4116e4c3351f286a0fc376b4e36"
PUBLIC_MODULES = {
    "FEX": "https://github.com/willfaust/FEX.git",
    "wine": "https://github.com/willfaust/wine.git",
    "dxmt": "https://github.com/willfaust/dxmt.git",
    "madeira-dock": "https://github.com/willfaust/madeira-dock.git",
}
RPMALLOC = "https://github.com/willfaust/rpmalloc.git"
STATUS_PATTERN = re.compile(r"^([ +\-U])([0-9a-f]{40})\s+(.+?)(?:\s+\(.+\))?$")


def git(path: Path, *args: str) -> str:
    command = ["git", "-C", str(path), *args]
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise ValueError(f"git command failed ({' '.join(args)}): {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def expected_gitlink(root: Path, path: str) -> str:
    line = git(root, "ls-tree", "HEAD", path)
    match = re.fullmatch(r"160000 commit ([0-9a-f]{40})\t" + re.escape(path), line)
    if not match:
        raise ValueError(f"missing exact submodule gitlink in {root}: {path}")
    return match.group(1)


def check_status(status: str) -> dict[str, str]:
    if not status.strip():
        raise ValueError("recursive submodule checkout contains no submodules")
    found: dict[str, str] = {}
    for line in status.splitlines():
        match = STATUS_PATTERN.match(line)
        if not match:
            raise ValueError(f"invalid recursive submodule status: {line}")
        state, sha, path = match.groups()
        if state != " ":
            raise ValueError(f"missing, dirty or mismatched submodule: {path} ({state})")
        if path in found:
            raise ValueError(f"duplicate submodule in checkout: {path}")
        found[path] = sha
    return found


def check_url(root: Path, submodule: str, expected: str) -> None:
    actual = git(root, "config", "-f", ".gitmodules", "--get", f"submodule.{submodule}.url")
    if actual != expected:
        raise ValueError(f"unexpected source for {submodule}: {actual}")


def verify(root: Path, revision: str = REVISION) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Madeira revision must be a full 40-character commit SHA")
    if git(root, "rev-parse", "HEAD") != revision:
        raise ValueError(f"Madeira checkout does not match pinned revision: {revision}")
    checked = check_status(git(root, "submodule", "status", "--recursive"))
    for path, url in PUBLIC_MODULES.items():
        check_url(root, path, url)
        expected = expected_gitlink(root, path)
        if checked.get(path) != expected:
            raise ValueError(f"{path} not checked out at exact pinned gitlink: {expected}")
        actual = git(root / path, "rev-parse", "HEAD")
        if actual != expected:
            raise ValueError(f"{path} HEAD is not the pinned commit: {expected}")
    fex = root / "FEX"
    check_url(fex, "External/rpmalloc", RPMALLOC)
    rpmalloc = expected_gitlink(fex, "External/rpmalloc")
    if checked.get("FEX/External/rpmalloc") != rpmalloc:
        raise ValueError(f"rpmalloc nested fork not at pinned commit: {rpmalloc}")
    if git(fex / "External/rpmalloc", "rev-parse", "HEAD") != rpmalloc:
        raise ValueError("nested rpmalloc checkout does not match the FEX gitlink")
    if len(checked) < len(PUBLIC_MODULES) + 1:
        raise ValueError("missing recursive Madeira dependencies")
    print(f"Verified published Madeira {revision}: {len(checked)} exact recursive gitlinks")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("vendor/Madeira"))
    parser.add_argument("--revision", default=os.environ.get("IDECK_MADEIRA_REV", REVISION))
    args = parser.parse_args()
    try:
        verify(args.root.resolve(), args.revision)
    except (OSError, ValueError) as exc:
        print(f"ERROR: public Madeira checkout invalid: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
