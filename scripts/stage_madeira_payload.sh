#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: stage_madeira_payload.sh /path/to/iDeck.app}"
SOURCE="${IDECK_MADEIRA_APP_ROOT:-$ROOT/vendor/Madeira/app/Madeira}"
GRAPHICS="${IDECK_MADEIRA_GRAPHICS:-d3d12}"
[[ "$GRAPHICS" == "d3d11" || "$GRAPHICS" == "d3d12" ]] || {
  echo "ERROR: unsupported Madeira graphics profile: $GRAPHICS" >&2; exit 2;
}
[[ "${IDECK_BUILD_WOW64:-0}" == "0" || "${IDECK_BUILD_WOW64:-0}" == "1" ]] || {
  echo "ERROR: IDECK_BUILD_WOW64 must be 0 or 1." >&2
  exit 2
}

[[ -d "$APP" ]] || { echo "ERROR: missing iDeck.app: $APP" >&2; exit 2; }
[[ -d "$SOURCE" ]] || { echo "ERROR: Madeira compiled resources missing: $SOURCE" >&2; exit 2; }

RUNTIME="$APP/MadeiraRuntime"
mkdir -p "$RUNTIME"

# Wine's crypt32 unix bridge requires the Mozilla trust bundle for TLS.
[[ -s "$SOURCE/cacert.pem" ]] && grep -q "BEGIN CERTIFICATE" "$SOURCE/cacert.pem" || {
  echo "ERROR: missing or invalid Madeira cacert.pem" >&2; exit 2;
}
cp "$SOURCE/cacert.pem" "$APP/cacert.pem"
for folder in legal licenses; do
  [[ -d "$SOURCE/$folder" ]] || {
    echo "ERROR: missing Madeira license directory: $folder" >&2; exit 2;
  }
  cp -R "$SOURCE/$folder" "$APP/$folder"
done

# The upstream Madeira bridge uses NSBundle.mainBundle for these paths.
# They must exist at the top level, not only under MadeiraRuntime.
for folder in aarch64-windows arm64ec-windows nls; do
  [[ -d "$SOURCE/$folder" ]] || { echo "ERROR: missing Madeira asset folder: $folder" >&2; exit 2; }
  cp -R "$SOURCE/$folder" "$APP/$folder"
done

# Source Wine farms may contain D3D12 DLLs even on clean checkouts.
# Remove them only from staging, never from the pinned source checkout.
if [[ "$GRAPHICS" == "d3d11" ]]; then
  for folder in aarch64-windows arm64ec-windows; do
    for module in madeira_d3d12.dll d3d12.dll d3d12core.dll; do
      rm -f "$APP/$folder/$module"
    done
  done
  if [[ "${IDECK_BUILD_WOW64:-0}" == "0" ]]; then
    for module in xtajit.dll wow64.dll wow64win.dll; do
      rm -f "$APP/aarch64-windows/$module"
    done
    rm -rf "$APP/i386-windows" "$RUNTIME/i386-windows"
  fi
  rm -rf "$APP/d3d12" "$RUNTIME/d3d12"
fi

[[ -s "$SOURCE/prefix-template.tar.gz" ]] || {
  echo "ERROR: missing Wine prefix-template.tar.gz" >&2; exit 2;
}
cp "$SOURCE/prefix-template.tar.gz" "$APP/prefix-template.tar.gz"
[[ "$(od -An -tx1 -N2 "$APP/prefix-template.tar.gz" | tr -d '[:space:]')" == "1f8b" ]] || {
  echo "ERROR: invalid Wine prefix archive gzip header" >&2; exit 2;
}

for path in aarch64-windows/d3d11.dll aarch64-windows/dxgi.dll \
            aarch64-windows/winemetal.dll aarch64-windows/kernel32.dll \
            aarch64-windows/user32.dll arm64ec-windows/ntdll.dll \
            arm64ec-windows/kernel32.dll arm64ec-windows/kernelbase.dll \
            arm64ec-windows/user32.dll arm64ec-windows/gdi32.dll \
            arm64ec-windows/ws2_32.dll arm64ec-windows/d3d9.dll \
            arm64ec-windows/vulkan-1.dll \
            arm64ec-windows/d3d11.dll arm64ec-windows/dxgi.dll \
            arm64ec-windows/d3d10core.dll \
            arm64ec-windows/xtajit64.dll arm64ec-windows/winemetal.dll \
            arm64ec-windows/dcomp.dll arm64ec-windows/ktmw32.dll arm64ec-windows/faultrep.dll arm64ec-windows/xaudio2_7.dll \
            arm64ec-windows/d3dx11_43.dll arm64ec-windows/d3dcompiler_47.dll arm64ec-windows/dinput8.dll; do
  FILE="$APP/$path"
  [[ -s "$FILE" ]] || { echo "ERROR: missing PE module: $path" >&2; exit 2; }
  [[ "$(head -c 2 "$FILE")" == "MZ" ]] || {
    echo "ERROR: not a Windows PE module: $path" >&2; exit 2;
  }
done

if [[ "$GRAPHICS" == "d3d12" ]]; then
  for module in madeira_d3d12.dll d3d12.dll d3d12core.dll; do
    [[ -s "$APP/arm64ec-windows/$module" ]] || {
      echo "ERROR: missing native D3D12 frontend: $module" >&2; exit 2;
    }
  done
  cmp -s "$APP/arm64ec-windows/madeira_d3d12.dll" "$APP/arm64ec-windows/d3d12.dll" || {
    echo "ERROR: bundled D3D12 is not the Madeira native D3D12 frontend." >&2
    exit 2
  }
fi

# Windows-side IPA signers enumerate bundle entries through APIs that cannot
# reliably inspect Unix symlinks. Package physical directories in the native
# runtime mirror, preserving the original top-level paths used by Madeira.
for folder in aarch64-windows arm64ec-windows nls; do
  cp -R "$APP/$folder" "$RUNTIME/$folder"
done
[[ -s "$RUNTIME/nls/locale.nls" ]] || {
  echo "ERROR: Wine locale.nls is missing" >&2; exit 2;
}

if [[ "${IDECK_BUILD_WOW64:-0}" == "1" && -s "$SOURCE/i386-windows/ntdll.dll" ]]; then
  for name in ntdll.dll kernel32.dll user32.dll d3d11.dll dxgi.dll; do
    [[ -s "$SOURCE/i386-windows/$name" ]] || {
      echo "ERROR: incomplete i386 Wine farm: $name" >&2; exit 2;
    }
  done
  for name in xtajit.dll wow64.dll wow64win.dll; do
    [[ -s "$SOURCE/aarch64-windows/$name" ]] || {
      echo "ERROR: missing native WoW64 host module: $name" >&2; exit 2;
    }
  done
  cp -R "$SOURCE/i386-windows" "$APP/i386-windows"
  cp -R "$APP/i386-windows" "$RUNTIME/i386-windows"
elif [[ "${IDECK_BUILD_WOW64:-0}" == "1" ]]; then
  echo "ERROR: requested WoW64, but the i386 DLL farm was not compiled." >&2
  exit 2
fi

# The patched wineserver substitutes only incompatible low-address x64
# LuaJIT binaries, and looks this up under WINEDLLPATH/compat/love.
[[ -s "$SOURCE/compat/love/lua51.dll" ]] || {
  echo "ERROR: GC64 LuaJIT compatibility DLL missing from native runtime" >&2
  exit 2
}
[[ "$(head -c 2 "$SOURCE/compat/love/lua51.dll")" == "MZ" ]] || {
  echo "ERROR: bundled LuaJIT is not a Windows PE" >&2
  exit 2
}
mkdir -p "$APP/compat/love" "$RUNTIME/compat/love"
cp "$SOURCE/compat/love/lua51.dll" "$APP/compat/love/lua51.dll"
cp "$SOURCE/compat/love/lua51.dll" "$RUNTIME/compat/love/lua51.dll"
[[ -s "$SOURCE/licenses/LuaJIT-MIT.txt" ]] || {
  echo "ERROR: missing LuaJIT MIT license notice" >&2
  exit 2
}

# Vulkan: Wine's ARM64EC winevulkan/vulkan-1 live OUTSIDE the arm64ec farm
# (every farm file is linked into every prefix, and a program probing for
# vulkan-1.dll must find none unless the session turns Vulkan on). The
# upstream WineProcessBridge links them per session from vulkan/.
for name in winevulkan.dll vulkan-1.dll; do
  FILE="$SOURCE/vulkan/arm64ec-windows/$name"
  [[ -s "$FILE" && "$(head -c 2 "$FILE")" == "MZ" ]] || {
    echo "ERROR: missing Vulkan ARM64EC module: vulkan/arm64ec-windows/$name" >&2; exit 2;
  }
done
mkdir -p "$APP/vulkan/arm64ec-windows" "$RUNTIME/vulkan/arm64ec-windows"
for file in "$SOURCE/vulkan/arm64ec-windows/"*.dll; do
  # vkd3d-proton's d3d12*.dll belongs to the licensed D3D12 profile only.
  case "$(basename "$file")" in d3d12*.dll) [[ "$GRAPHICS" == "d3d12" ]] || continue ;; esac
  cp "$file" "$APP/vulkan/arm64ec-windows/"
  cp "$file" "$RUNTIME/vulkan/arm64ec-windows/"
done

# OpenGL / Vulkan host libraries (scripts/build_madeira_gl_vulkan.sh):
# MoltenVK for winevulkan and Zink, Mesa OSMesa + Zink for desktop OpenGL.
# The bridge reads them from <bundle>/gl via NSBundle.mainBundle.
for name in libMoltenVK.dylib libOSMesa.dylib; do
  [[ -s "$SOURCE/gl/$name" ]] || {
    echo "ERROR: missing OpenGL/Vulkan runtime: gl/$name (run scripts/build_madeira_gl_vulkan.sh)" >&2; exit 2;
  }
  # Mach-O 64-bit magic followed by CPU_TYPE_ARM64 (0x0100000c), little endian.
  [[ "$(od -An -tx1 -N8 "$SOURCE/gl/$name" | tr -d '[:space:]')" == "cffaedfe0c000001" ]] || {
    echo "ERROR: gl/$name is not an arm64 iOS dylib" >&2; exit 2;
  }
done
mkdir -p "$APP/gl"
cp "$SOURCE/gl/libMoltenVK.dylib" "$SOURCE/gl/libOSMesa.dylib" "$APP/gl/"
for license in MoltenVK-Apache-2.0.txt SPIRV-Cross-Apache-2.0.txt SPIRV-Tools-Apache-2.0.txt \
               cereal-BSD-3-Clause.txt Mesa-license.rst; do
  [[ -s "$APP/licenses/$license" ]] || {
    echo "ERROR: missing OpenGL/Vulkan license notice: licenses/$license" >&2; exit 2;
  }
done
if [[ -n "${IDECK_CODESIGN_IDENTITY:-}" ]]; then
  for library in "$APP/gl/libMoltenVK.dylib" "$APP/gl/libOSMesa.dylib"; do
    codesign --force --sign "$IDECK_CODESIGN_IDENTITY" --timestamp=none "$library"
  done
fi

# Official Microsoft VC++ libraries are not included in Madeira's git checkout.
# When the owner supplies an authorized, complete distribution, stage it in
# the exact location read by the upstream WineProcessBridge. No fake DLLs.
VCRT_SOURCE="${IDECK_VCRUNTIME_DIR:-$SOURCE/x86_64-vcruntime}"
if [[ -d "$VCRT_SOURCE" ]]; then
  for name in concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll \
              msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll \
              vcamp140.dll vccorlib140.dll vcomp140.dll \
              vcruntime140.dll vcruntime140_1.dll vcruntime140_threads.dll \
              mfc140.dll mfc140u.dll; do
    [[ -s "$VCRT_SOURCE/$name" ]] && [[ "$(head -c 2 "$VCRT_SOURCE/$name")" == "MZ" ]] || {
      echo "ERROR: incomplete Microsoft VC++ runtime: $name" >&2; exit 2;
    }
  done
  cp -R "$VCRT_SOURCE" "$APP/x86_64-vcruntime"
  echo "Staged owner-supplied Microsoft VC++ runtime."
elif [[ "${IDECK_REQUIRE_VCRUNTIME:-0}" == "1" ]]; then
  echo "ERROR: provide authorized Microsoft VC++ DLLs in IDECK_VCRUNTIME_DIR" >&2
  exit 2
else
  echo "WARNING: Microsoft VC++ runtime absent; games needing it may fail."
fi

if [[ "$GRAPHICS" == "d3d12" ]]; then
mkdir -p "$APP/d3d12" "$RUNTIME/d3d12"
for name in canary_vs.dxil canary_ps.dxil canary_layout_vs.dxil canary_layout_ps.dxil; do
  [[ -s "$SOURCE/d3d12/$name" ]] || {
    echo "ERROR: missing D3D12 canary shader: $name" >&2; exit 2;
  }
  cp "$SOURCE/d3d12/$name" "$APP/d3d12/$name"
  cp "$SOURCE/d3d12/$name" "$RUNTIME/d3d12/$name"
done
for name in NOTICE.txt METAL-SHADER-CONVERTER-AGREEMENT.txt LICENSE-metal-shader-converter-headers.txt; do
  [[ -f "$SOURCE/d3d12/$name" ]] || { echo "ERROR: missing converter legal notice: $name" >&2; exit 2; }
  cp "$SOURCE/d3d12/$name" "$APP/d3d12/$name"
  cp "$SOURCE/d3d12/$name" "$RUNTIME/d3d12/$name"
done
if [[ "${IDECK_MSC_REQUIRE_BETA3:-0}" == "1" ]]; then
  for name in METAL-SHADER-CONVERTER-4.0-BETA-3-LICENSE.rtf apple-msc-4.0-beta-3-provenance.json; do
    [[ -s "$SOURCE/d3d12/$name" ]] || { echo "ERROR: audited Apple 4.0 beta 3 converter notice missing: $name" >&2; exit 2; }
    cp "$SOURCE/d3d12/$name" "$APP/d3d12/$name"
    cp "$SOURCE/d3d12/$name" "$RUNTIME/d3d12/$name"
  done
fi

[[ "${IDECK_ACCEPT_METAL_CONVERTER_LICENSE:-0}" == "1" ]] || {
  echo "ERROR: Metal Shader Converter redistribution rights not confirmed." >&2
  echo "Set IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 after reviewing the upstream Apple agreement." >&2
  exit 2
}
[[ -s "$SOURCE/d3d12/libmetalirconverter.dylib" ]] || {
  echo "ERROR: licensed Metal Shader Converter iOS dylib not available." >&2
  exit 2
}
cp "$SOURCE/d3d12/libmetalirconverter.dylib" "$APP/d3d12/libmetalirconverter.dylib"
cp "$APP/d3d12/libmetalirconverter.dylib" "$RUNTIME/d3d12/libmetalirconverter.dylib"

# Dynamic code must be signed by the same signing workflow as the host IPA.
# An ad hoc signature alone is not a distribution/developer identity.
if [[ -n "${IDECK_CODESIGN_IDENTITY:-}" ]]; then
  for library in "$APP/d3d12/libmetalirconverter.dylib" \
                 "$RUNTIME/d3d12/libmetalirconverter.dylib"; do
    codesign --force --sign "$IDECK_CODESIGN_IDENTITY" --timestamp=none "$library"
  done
fi
else
  if find "$APP" -type f -name 'libmetalirconverter.dylib' -print -quit | grep -q .; then
    echo "ERROR: Apple Metal Shader Converter leaked into a D3D11 IPA." >&2
    exit 2
  fi
fi

if [[ "${IDECK_BUNDLE_WINE_MONO:-0}" == "1" ]]; then
  if [[ -s "$SOURCE/wine-mono/bin/libmono-2.0-x86.dll" ]]; then
    cp -R "$SOURCE/wine-mono" "$APP/wine-mono"
  else
    MONO_ROOT="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}/build/wine-mono"
    [[ -f "$MONO_ROOT/fetch.sh" && -f "$MONO_ROOT/bundle.sh" ]] || {
      echo "ERROR: Wine Mono files/scripts not available" >&2; exit 2;
    }
    bash "$MONO_ROOT/fetch.sh"
    bash "$MONO_ROOT/bundle.sh" "$APP/wine-mono"
  fi
  [[ -s "$APP/wine-mono/bin/libmono-2.0-x86.dll" ]] || {
    echo "ERROR: incomplete Wine Mono payload" >&2; exit 2;
  }
fi

echo "Madeira Wine/DXMT resources staged under iDeck.app (graphics: $GRAPHICS)."
echo "Native libraries must also be linked and the final app must be signed and device-tested."
