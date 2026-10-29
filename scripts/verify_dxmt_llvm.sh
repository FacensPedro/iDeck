#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
LLVM="$MD/toolchains/llvm-ios-build"
python3 "$ROOT/scripts/llvm_ios_sdk.py" check --build "$LLVM" --ref "${IDECK_LLVM_REF:-llvmorg-15.0.7}"
# Exercise the actual cross-compiler and transitive includes before Wine/FEX.
xcrun --sdk iphoneos clang++ -arch arm64 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=18.0 -std=c++20 -fsyntax-only \
  -I"$LLVM/include" -x c++ - <<'CPP'
#include <llvm/Config/llvm-config.h>
#include <llvm/Bitcode/BitcodeReader.h>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/PassManager.h>
#include <llvm/IR/Intrinsics.h>
#include <llvm/ADT/APFloat.h>
#include <llvm/ADT/Optional.h>
static_assert(LLVM_VERSION_MAJOR == 15, "DXMT requires LLVM 15");
CPP
