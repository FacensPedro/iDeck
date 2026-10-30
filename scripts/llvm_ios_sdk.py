#!/usr/bin/env python3
"""Make cached iOS LLVM builds usable without the original source checkout."""
import argparse
import json
import shutil
from pathlib import Path

HEADERS = (
    'llvm/Bitcode/BitcodeReader.h', 'llvm/Bitcode/BitcodeWriter.h',
    'llvm/IR/Constants.h', 'llvm/IR/LLVMContext.h', 'llvm/IR/DataLayout.h',
    'llvm/IR/Module.h', 'llvm/IR/PassManager.h', 'llvm/ADT/APFloat.h',
    'llvm/ADT/Optional.h', 'llvm/ADT/SmallVector.h',
)
GENERATED = ('llvm/Config/llvm-config.h', 'llvm/Config/abi-breaking.h',
             'llvm/IR/IntrinsicEnums.inc', 'llvm/IR/IntrinsicImpl.inc')
ARCHIVES = ('LLVMCore', 'LLVMSupport', 'LLVMBitReader', 'LLVMBitWriter')
MARKER = 'ideck-sdk.json'


def validate(build: Path, ref: str, manifest: bool = True) -> None:
    required = [build / 'include' / name for name in HEADERS + GENERATED]
    required += [build / 'lib' / f'lib{name}.a' for name in ARCHIVES]
    missing = [str(path) for path in required if not path.is_file() or not path.stat().st_size]
    if missing:
        raise ValueError('Incomplete iOS LLVM SDK: ' + ', '.join(missing))
    if manifest:
        info = json.loads((build / MARKER).read_text())
        if info != {'schema': 1, 'ref': ref}:
            raise ValueError('iOS LLVM SDK revision mismatch; rebuild required')


def stage(source: Path, build: Path, ref: str) -> None:
    # Never stamp a partial copy as reusable. Generated .h/.inc files stay
    # in the build tree; source templates have different (.in) filenames.
    (build / MARKER).unlink(missing_ok=True)
    for name in HEADERS:
        path = source / 'include' / name
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f'Missing LLVM source header: {path}')
    shutil.copytree(source / 'include', build / 'include', dirs_exist_ok=True)
    validate(build, ref, manifest=False)
    (build / MARKER).write_text(json.dumps({'schema': 1, 'ref': ref}) + '\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'stage'))
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--ref', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'stage':
            if args.source is None:
                parser.error('stage requires --source')
            stage(args.source, args.build, args.ref)
        else:
            validate(args.build, args.ref)
    except (OSError, ValueError) as error:
        parser.exit(2, f'ERROR: {error}\n')


if __name__ == '__main__':
    main()
