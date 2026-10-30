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

for architecture in x86_64 i686; do
  if [[ "$architecture" == "i686" ]]; then
    suffix=x86
    bits=32
  else
    suffix=x64
    bits=64
  fi
  CC="$BIN/$architecture-w64-mingw32-clang"
  [[ -x "$CC" ]] || { echo "ERROR: llvm-mingw compiler missing: $CC" >&2; exit 2; }
  "$CC" -O2 -std=c11 -Wall -Wextra -DIDECK_GUEST_BITS="$bits" \
    -D_WIN32_WINNT=0x0601 \
    "$ROOT/tests/device/ideck_guest_audio_input_probe.c" \
    -o "$OUT/ideck-guest-audio-input-$suffix.exe" -municode \
    -lwinmm -lxinput9_1_0 -luser32 -lgdi32 -lkernel32
done

CXX="$BIN/x86_64-w64-mingw32-clang++"
"$CXX" -O2 -std=c++17 -Wall -Wextra \
  "$ROOT/tests/device/ideck_d3d12_frame_probe.cpp" \
  -o "$OUT/ideck-d3d12-frame-probe-x64.exe" -municode \
  -ld3d12 -ldxgi -luuid -luser32 -lkernel32

python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-guest-smoke-32.exe" > "$OUT/guest-smoke-32.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-guest-smoke-64.exe" > "$OUT/guest-smoke-64.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-d3d11-frame-probe-x64.exe" > "$OUT/guest-d3d11.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-d3d11-frame-probe-x86.exe" > "$OUT/guest-d3d11-32.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-guest-audio-input-x64.exe" > "$OUT/guest-audio-input-x64.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-guest-audio-input-x86.exe" > "$OUT/guest-audio-input-x86.json"
python3 "$ROOT/scripts/inspect_windows_game_pe.py" "$OUT/ideck-d3d12-frame-probe-x64.exe" > "$OUT/guest-d3d12-x64.json"
python3 - "$OUT" <<'PY'
import json
import sys
from pathlib import Path
directory = Path(sys.argv[1])
for filename, architecture in (("guest-smoke-32.json", "x86"), ("guest-smoke-64.json", "x86_64"), ("guest-d3d11.json", "x86_64"), ("guest-d3d11-32.json", "x86"), ("guest-audio-input-x64.json", "x86_64"), ("guest-audio-input-x86.json", "x86"), ("guest-d3d12-x64.json", "x86_64")):
    data = json.loads((directory / filename).read_text(encoding="utf-8"))
    if data["guest_architecture"] != architecture:
        raise SystemExit(f"incorrect PE architecture in {filename}")
d3d11 = json.loads((directory / "guest-d3d11.json").read_text())
if not d3d11["possible_runtime_requirements"]["d3d11"]:
    raise SystemExit("D3D11 frame probe does not import the real Direct3D 11 API")
d3d11_32 = json.loads((directory / "guest-d3d11-32.json").read_text())
if not d3d11_32["requires_wow64"] or not d3d11_32["possible_runtime_requirements"]["d3d11"]:
    raise SystemExit("WoW64 frame probe must be a real i386 D3D11 Windows executable")
for suffix in ("x64", "x86"):
    candidate = json.loads((directory / f"guest-audio-input-{suffix}.json").read_text())
    if not candidate["possible_runtime_requirements"]["xinput"]:
        raise SystemExit(f"Missing actual Windows XInput import in {suffix} test executable")
d3d12 = json.loads((directory / "guest-d3d12-x64.json").read_text())
if not d3d12["possible_runtime_requirements"]["d3d12"]:
    raise SystemExit("D3D12 frame probe lacks the Windows D3D12 import")
import hashlib
manifest = {
    "schema": 1,
    "device_execution_verified": False,
    "probes": {
        path.name: {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "bytes": path.stat().st_size}
        for path in sorted(directory.glob("*.exe"))
    },
}
(directory / "probe-build-manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("Compiled Win32 PE32/PE32+, x86/x64 D3D11, x64 D3D12, PCM, XInput and touch probes.")
print("These must still be launched on the iPad: compilation is not execution.")
PY
