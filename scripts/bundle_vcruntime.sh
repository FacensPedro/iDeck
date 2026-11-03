#!/usr/bin/env bash
# Builds tools/vcrt-bundle for the Mac running the build and puts Microsoft's
# Visual C++ runtimes (extracted, never run) into the app as vcruntime-bundle.
# usage: scripts/bundle_vcruntime.sh <iDeck.app>
set -euo pipefail
APP="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MSPACK="$ROOT/iDeck/ThirdParty/libmspack"
for c in "$ROOT/iDeck/NativeRuntime/VCArchiveExtractor.c" "$MSPACK"/{cabc,cabd,crc32,lzxd,mszipd,qtmd,system}.c; do
  xcrun clang -O2 -c -I "$MSPACK" -I "$ROOT/iDeck/NativeRuntime" "$c" -o "$WORK/$(basename "$c").o"
done
xcrun swiftc -O -import-objc-header "$ROOT/iDeck/NativeRuntime/VCArchiveExtractor.h" -I "$MSPACK" \
  "$ROOT/tools/vcrt-bundle/main.swift" "$ROOT/iDeck/VisualCRuntimeBootstrap.swift" "$WORK"/*.o -o "$WORK/vcrt-bundle"
"$WORK/vcrt-bundle" "$WORK/out"
rm -rf "$APP/vcruntime-bundle"
cp -R "$WORK/out/vcruntime" "$APP/vcruntime-bundle"
echo "Bundled Visual C++: $(find "$APP/vcruntime-bundle" -type f | wc -l | tr -d ' ') files"
