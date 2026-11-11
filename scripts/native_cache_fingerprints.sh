#!/usr/bin/env bash
# Cache keys for the slow native build stages, from what each stage really reads.
#
# The stages used to be keyed on the whole of scripts/fetch_madeira_sources.sh (and
# every file in patches/), so a patch to the iOS bridge or to ntdll's unix side
# rebuilt the i386 Wine farm (about 9 minutes), GnuTLS/FFmpeg/FreeType and
# Mesa/MoltenVK although none of them reads those files.  Run after the fetch has
# checked out and patched vendor/Madeira; prints `name=fingerprint` lines:
#
#   i386  wine and dxmt submodules as patched, and Madeira's build scripts and
#         tools, without the iOS-only trees (app/, the *-unix and wineserver builds)
#   deps  build/gnutls-ios, build/ffmpeg, build/freetype-ios
#   gl    build/moltenvk-ios, build/mesa-ios
#
# A fingerprint covers the commit, the tracked changes and the untracked files of
# its paths, so a new patch that does touch a stage's inputs still rebuilds it.
set -euo pipefail

MD="${1:?Usage: native_cache_fingerprints.sh /path/to/vendor/Madeira}"
[[ -d "$MD/.git" || -f "$MD/.git" ]] || { echo "ERROR: not a Madeira checkout: $MD" >&2; exit 2; }

hash_stream() { shasum -a 256 | cut -d' ' -f1; }

# The state of `paths` (pathspecs) in the repository at $1.
tree_state() {
  local repo="$1"; shift
  git -C "$repo" rev-parse HEAD
  git -C "$repo" diff HEAD -- "$@"
  git -C "$repo" ls-files --others --exclude-standard -z -- "$@" | sort -z |
    while IFS= read -r -d '' file; do
      printf '%s ' "$file"
      shasum -a 256 < "$repo/$file" | cut -d' ' -f1
    done
}

# iOS-only inputs: compiled into the app or its unix libraries, never into a PE farm.
IOS_ONLY=(':(exclude)app' ':(exclude)build/ntdll-unix' ':(exclude)build/win32u-unix'
          ':(exclude)build/wineserver' ':(exclude)build/dxmt-ios' ':(exclude)docs'
          ':(exclude)toolchains' ':(exclude)research' ':(exclude)wine' ':(exclude)dxmt'
          ':(exclude)FEX' ':(exclude)madeira-dock')

i386="$( { tree_state "$MD" . "${IOS_ONLY[@]}"
           for sub in wine dxmt; do
             [[ -e "$MD/$sub/.git" ]] || { echo "ERROR: missing submodule $sub" >&2; exit 2; }
             tree_state "$MD/$sub" .
           done; } | hash_stream )"
deps="$(tree_state "$MD" build/gnutls-ios build/ffmpeg build/freetype-ios | hash_stream)"
gl="$(tree_state "$MD" build/moltenvk-ios build/mesa-ios | hash_stream)"

echo "i386=$i386"
echo "deps=$deps"
echo "gl=$gl"
