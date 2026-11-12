"""Shared helpers for the host tests: the repository root and cached source reads."""
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@lru_cache(maxsize=None)
def repo_text(path: str) -> str:
    """Text of a repository file, read once per test run."""
    return (ROOT / path).read_text(encoding="utf-8")


def patch_group(name: str) -> str:
    """The group patches/series.txt applies `name` in, or "" when it is not listed."""
    for line in repo_text("patches/series.txt").splitlines():
        parts = line.split("#", 1)[0].split()
        if len(parts) == 3 and parts[2] == name:
            return parts[0]
    return ""
