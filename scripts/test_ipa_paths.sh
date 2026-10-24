#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc "$ROOT/iDeck/IPAArchivePath.swift" "$ROOT/tests/host/IPAArchivePathTests.swift" -o "$OUT/ipa-path-tests"
"$OUT/ipa-path-tests"
