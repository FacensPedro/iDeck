#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MADEIRA="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
BIN="$MADEIRA/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
OUT="${IDECK_DEVICE_PROBE_DIR:-$ROOT/build/madeira-device-probes}"
mkdir -p "$OUT"

for architecture in x86_64 i686; do
  case "$architecture" in
    x86_64) bits=64 ;;
    i686) bits=32 ;;
  esac
  compiler="$BIN/$architecture-w64-mingw32-clang"
  [[ -x "$compiler" ]] || { echo "ERROR: llvm-mingw compiler missing: $compiler" >&2; exit 2; }
  "$compiler" -O2 -Wall -Wextra -Werror -DIDECK_GUEST_BITS="$bits" \
    "$ROOT/tests/device/ideck_guest_smoke.c" -o "$OUT/ideck-guest-smoke-$bits.exe"
done

for architecture in x86_64 i686; do
  if [[ "$architecture" == "i686" ]]; then
    suffix=x86
  else
    suffix=x64
  fi
  CXX="$BIN/$architecture-w64-mingw32-clang++"
  [[ -x "$CXX" ]] || { echo "ERROR: llvm-mingw C++ compiler missing: $CXX" >&2; exit 2; }
  "$CXX" -O2 -std=c++17 -Wall -Wextra \
    "$ROOT/tests/device/ideck_d3d11_frame_probe.cpp" \
    -o "$OUT/ideck-d3d11-frame-probe-$suffix.exe" -municode \
    -ld3d11 -ldxgi -luuid -luser32 -lkernel32
done

python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-guest-smoke-32.exe" > "$OUT/guest-smoke-32.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-guest-smoke-64.exe" > "$OUT/guest-smoke-64.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-d3d11-frame-probe-x64.exe" > "$OUT/guest-d3d11.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-d3d11-frame-probe-x86.exe" > "$OUT/guest-d3d11-32.json"
python3 - "$OUT" <<'PY'
import json
import sys
from pathlib import Path
directory = Path(sys.argv[1])
for filename, architecture in (("guest-smoke-32.json", "x86"), ("guest-smoke-64.json", "x86_64"), ("guest-d3d11.json", "x86_64"), ("guest-d3d11-32.json", "x86")):
    data = json.loads((directory / filename).read_text(encoding="utf-8"))
    if data["guest_architecture"] != architecture:
        raise SystemExit(f"incorrect PE architecture in {filename}")
d3d11 = json.loads((directory / "guest-d3d11.json").read_text())
if not d3d11["possible_runtime_requirements"]["d3d11"]:
    raise SystemExit("D3D11 frame probe does not import the real Direct3D 11 API")
d3d11_32 = json.loads((directory / "guest-d3d11-32.json").read_text())
if not d3d11_32["requires_wow64"] or not d3d11_32["possible_runtime_requirements"]["d3d11"]:
    raise SystemExit("WoW64 frame probe must be a real i386 D3D11 Windows executable")
print("Compiled original Win32 32/64-bit guest probes and x64/i386 D3D11 render-loop probes.")
print("These must still be launched on the iPad: compilation is not execution.")
PY
