#!/usr/bin/env bash
# Checks that llvm-mingw's target wrappers really call ccache (CCACHE set in the job
# environment): one small file compiled twice must be a cache hit the second time.
# Only a warning when it is not, since the build is still correct without ccache.
set -euo pipefail

TOOLCHAIN="${1:?Usage: check_mingw_ccache.sh /path/to/llvm-mingw}"
CC="$TOOLCHAIN/bin/i686-w64-mingw32-clang"
[[ -x "$CC" ]] || { echo "ERROR: missing $CC" >&2; exit 2; }
command -v ccache >/dev/null || { echo "::warning::ccache is not installed; Windows compilers run uncached"; exit 0; }
[[ -n "${CCACHE:-}" ]] || { echo "::warning::CCACHE is not set; Windows compilers run uncached"; exit 0; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'int ideck_ccache_probe(int x) { return x * %d; }\n' "$RANDOM$RANDOM" > "$work/probe.c"
hits() { ccache --print-stats | awk -F'\t' '$1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { n += $2 } END { print n + 0 }'; }
before="$(hits)"
"$CC" -O2 -c "$work/probe.c" -o "$work/a.o"
"$CC" -O2 -c "$work/probe.c" -o "$work/b.o"
after="$(hits)"
if (( after > before )); then
  echo "ccache wraps the llvm-mingw compilers (probe hit)"
else
  echo "::warning::llvm-mingw compilers did not hit ccache; the Wine farms compile uncached"
fi
ccache --zero-stats >/dev/null
