#!/usr/bin/env python3
"""Add Wine's WMI channel to the session log.

An EA game binds its licence to a hash of the machine and reads the values through
WMI (wbemprox): the board, the BIOS, the Windows install, the graphics card.  A game
that computes another hash than the licence carries says nothing; it starts EA's
activation window.  With trace+wbemprox the log names every query and property the
game asked for, and iDeck's bug report shows them (EAActivationTrace).

Only programs that use WMI print these lines.
"""
import sys
from pathlib import Path

OLD = ('setenv("WINEDEBUG", "err+all,fixme+all,warn+module,warn+file,trace+process,trace+module,'
       'trace+loaddll,trace+loadorder,trace+win,trace+user32,trace+syscall,trace+file", 1);')
NEW = OLD.replace('trace+file", 1);', 'trace+file,trace+wbemprox", 1);')


def main(root: str) -> int:
    path = Path(root) / "app/Madeira/WineProcessBridge.m"
    text = path.read_text()
    if NEW in text:
        print("WineProcessBridge.m: trace+wbemprox already in the verbose channels")
        return 0
    if text.count(OLD) != 1:
        print("ERROR: WineProcessBridge.m: verbose WINEDEBUG list not found", file=sys.stderr)
        return 2
    path.write_text(text.replace(OLD, NEW))
    print("WineProcessBridge.m: trace+wbemprox added to the verbose channels")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
