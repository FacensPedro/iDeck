#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: Metal shader compilation requires macOS." >&2
  exit 2
fi

for tool in xcrun xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: missing Xcode command: $tool" >&2
    exit 2
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ideck-metal.XXXXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/probe.metal" <<'METAL'
#include <metal_stdlib>
using namespace metal;
kernel void ideck_toolchain_probe(device float *output [[buffer(0)]], uint index [[thread_position_in_grid]]) {
    output[index] = float(index);
}
METAL

check_metal() {
  rm -f "$WORK_DIR/probe.air"
  xcrun --sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
    -c "$WORK_DIR/probe.metal" -o "$WORK_DIR/probe.air" > "$WORK_DIR/probe.log" 2>&1 && \
    [[ -s "$WORK_DIR/probe.air" ]]
}

if check_metal; then
  echo "Metal Toolchain is ready for DXMT shaders."
  exit 0
fi

cat "$WORK_DIR/probe.log" >&2
echo "Installing the optional Xcode Metal Toolchain..." >&2
xcodebuild -downloadComponent metalToolchain
xcrun --kill-cache

if ! check_metal; then
  cat "$WORK_DIR/probe.log" >&2
  echo "ERROR: Metal Toolchain installation did not produce a working macOS Metal shader compiler." >&2
  exit 1
fi

echo "Metal Toolchain installed and compiler probe succeeded."
