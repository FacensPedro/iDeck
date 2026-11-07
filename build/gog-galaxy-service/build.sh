#!/bin/sh
# Builds GalaxyCommunication (main.c, from Madeira) into iDeck's resources. Needs
# llvm-mingw (GOG_CC, default aarch64-w64-mingw32-clang on PATH); the result is committed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${GOG_CC:=aarch64-w64-mingw32-clang}"
"$GOG_CC" -Os -municode -s "$ROOT/build/gog-galaxy-service/main.c" -ladvapi32 \
    -o "$ROOT/iDeck/Resources/Galaxy/madeira-galaxy-service.exe"
