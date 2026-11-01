#!/usr/bin/env python3
"""Checks iDeck's language boundaries (docs/LANGUAGE_ARCHITECTURE.md).

Exit status 0 when every rule holds; otherwise prints each violation and
exits 1. Run from the repository root or pass it as the first argument.
"""
from __future__ import annotations

import pathlib
import re
import sys

CXX_MARKERS = re.compile(r"^\s*(namespace\s+\w|template\s*<|class\s+\w+[^;]*\{|using\s+namespace|#include\s*<(vector|string|memory|map|mutex|atomic)>)|std::", re.M)
CPLUSPLUS_BLOCK = re.compile(r"#if(def)?\s*(defined\s*\(\s*)?__cplusplus.*?#endif", re.S)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def has_cxx(text: str) -> bool:
    body = CPLUSPLUS_BLOCK.sub("", strip_comments(text))
    return bool(CXX_MARKERS.search(body))


def check(root: pathlib.Path) -> list[str]:
    app = root / "iDeck"
    problems: list[str] = []

    # 1. Swift sees no C++.
    bridging = app / "iDeck-Bridging-Header.h"
    for name in re.findall(r'#import\s+"([^"]+)"', bridging.read_text()):
        header = app / name
        if not name.endswith(".h"):
            problems.append(f"bridging header imports non-C header {name}")
        elif not header.exists():
            problems.append(f"bridging header imports missing {name}")
        elif has_cxx(header.read_text(errors="replace")):
            problems.append(f"{name} is imported by Swift but contains C++")
    project = (root / "iDeck.xcodeproj" / "project.pbxproj").read_text()
    if re.search(r"SWIFT_OBJC_INTEROP_MODE\s*=\s*objcxx", project):
        problems.append("Swift C++ interoperability mode is on")

    sources = [p for p in app.rglob("*") if p.is_file()]

    # 2. .hpp only from .cpp / .mm.
    for path in sources:
        if path.suffix in {".swift", ".c", ".m", ".h"}:
            for inc in re.findall(r'#(?:include|import)\s+"([^"]+\.hpp)"', path.read_text(errors="replace")):
                problems.append(f"{path.relative_to(root)} includes C++ header {inc}")

    # 3. Every .cpp is reachable through Objective-C++ or extern "C".
    mm_text = "\n".join(p.read_text(errors="replace") for p in sources if p.suffix == ".mm")
    for path in sources:
        if path.suffix != ".cpp":
            continue
        text = path.read_text(errors="replace")
        own_header = path.with_suffix(".hpp").name
        if 'extern "C"' not in text and own_header not in mm_text:
            problems.append(f"{path.relative_to(root)} has no extern \"C\" ABI and no Objective-C++ bridge")

    # 4. .c is C.
    for path in sources:
        if path.suffix == ".c" and has_cxx(path.read_text(errors="replace")):
            problems.append(f"{path.relative_to(root)} contains C++")

    # 5. No Python in the app.
    for path in sources:
        if path.suffix == ".py":
            problems.append(f"{path.relative_to(root)}: Python inside the app target")

    # 6. No hand-written zlib/inflate in Swift.
    for path in sources:
        if path.suffix == ".swift" and re.search(r"\binflate(Init|Init2_|End)?\s*\(\s*&", path.read_text(errors="replace")):
            problems.append(f"{path.relative_to(root)} drives zlib directly; use the C/C++ codecs")
    return problems


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    problems = check(root)
    for problem in problems:
        print("language-layers:", problem)
    print(f"language-layers: {'OK' if not problems else f'{len(problems)} problem(s)'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
