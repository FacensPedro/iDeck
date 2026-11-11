#!/usr/bin/env python3
"""Keep the process environment off freed memory when a Windows child starts.

Upstream Wine forks before it calls putenv( winedebug ): the string then belongs to
the child process, and the parent frees its own copy.  Madeira's iOS spawn_process
creates a thread instead (build/ntdll-unix/process_ios.c), so putenv() stores the
pointer in the one environment every thread of iDeck shares, and NtCreateUserProcess
frees it right after spawn_process returns.  From then on environ holds a dangling
entry that getenv(), setenv() and every library that walks the environment read.

setenv() copies the value, so the environment owns its string.
"""
import sys
from pathlib import Path

OLD = "    if (winedebug) putenv( winedebug );\n"
NEW = '''    /* iDeck: the caller frees winedebug when this returns, and this child is a thread
     * of the same process: the environment gets its own copy (setenv), not the pointer. */
    if (winedebug)
    {
        char *value = strchr( winedebug, '=' );
        if (value)
        {
            *value = 0;
            setenv( winedebug, value + 1, 1 );
            *value = '=';
        }
    }
'''
MARKER = "the environment gets its own copy (setenv), not the pointer"


def main(root: str) -> int:
    path = Path(root) / "build/ntdll-unix/process_ios.c"
    text = path.read_text()
    if MARKER in text:
        print("process_ios.c: child WINEDEBUG already copied into the environment")
        return 0
    start = text.find("#ifdef WINE_IOS\n    /* iOS: create a thread instead of fork+exec */")
    end = text.find("#else", start)
    if start < 0 or end < 0 or text.count(OLD, start, end) != 1:
        print("ERROR: process_ios.c: iOS spawn_process putenv not found", file=sys.stderr)
        return 2
    position = text.index(OLD, start, end)
    path.write_text(text[:position] + NEW + text[position + len(OLD):])
    print("process_ios.c: child WINEDEBUG copied into the environment instead of aliased")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
