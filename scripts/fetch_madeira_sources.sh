#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/vendor/Madeira}"
REV="279fd0f83170425db002fe25d6bd62f6355f497d"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
if [ ! -d "$DEST/.git" ]; then
  mkdir -p "$(dirname "$DEST")"
  git clone https://github.com/willfaust/Madeira.git "$DEST"
fi

git -C "$DEST" fetch origin "$REV"
git -C "$DEST" checkout --detach "$REV"
git -C "$DEST" submodule sync --recursive
git -C "$DEST" submodule update --init --recursive

for dir in FEX wine dxmt; do
  test -d "$DEST/$dir/.git" -o -f "$DEST/$dir/.git" || {
    echo "Missing Madeira dependency: $dir (check published submodule commits)." >&2
    exit 1
  }
done

echo "Madeira sources checked out at $REV"
echo "These are SOURCES only. iOS libraries are not compiled or linked into iDeck."
echo "Read $DEST/docs/BUILDING.md for the platform toolchains and licensed prerequisites."
