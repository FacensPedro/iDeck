#!/usr/bin/env python3
"""Let the app tear down a finished 32-bit program's 4 GB window right away.

build/ntdll-unix/virtual_ios.c tears down the window of an exited 32-bit
pseudo-process only when the NEXT 32-bit process reserves one
(ios_wow_reclaim_dead_windows, release-on-next-adopt): its memory stays mapped
until then. That function already waits out the settle interval, keeps a window
any of whose threads still exists (ios_thread_registry_range_busy), drops native
D3D9 objects first and leaves the range PROT_NONE. This overlay exports it as
ideck_wow_reclaim_dead_windows(), which iDeck calls from a plain background
thread (never one inside the window) once the session's worker and wineserver
have stopped. The JIT pool is not touched.
"""
import sys
from pathlib import Path

MARKER = "ideck_wow_reclaim_dead_windows"
ANCHOR = '''/***********************************************************************
 *           ios_wow_window_reserve
'''
ADDITION = '''/* iDeck: the same reclaim, from the app once a session has fully ended, so a
 * finished 32-bit program's window is returned to iOS without waiting for the
 * next 32-bit program. Returns how many windows are still waiting (a live thread
 * kept them, or the teardown failed). */
int ideck_wow_reclaim_dead_windows(void)
{
    unsigned i;
    int waiting = 0;

    ios_wow_reclaim_dead_windows();
    pthread_mutex_lock( &ios_wow_mutex );
    for (i = 0; i < IOS_WOW_MAX_WINDOWS; i++)
        if (ios_wow_windows[i].base && ios_wow_windows[i].dead) waiting++;
    pthread_mutex_unlock( &ios_wow_mutex );
    dprintf( 2, "[wow-window] after-session reclaim: %d window(s) still waiting\\n", waiting );
    return waiting;
}

'''


def main(madeira: Path) -> int:
    source = madeira / "build/ntdll-unix/virtual_ios.c"
    text = source.read_text()
    if MARKER in text:
        return 0
    if text.count(ANCHOR) != 1 or "static void ios_wow_reclaim_dead_windows(void)" not in text:
        print("ERROR: virtual_ios.c WoW window code changed; after-session reclaim not applied", file=sys.stderr)
        return 2
    source.write_text(text.replace(ANCHOR, ADDITION + ANCHOR))
    print("Applied after-session WoW window reclaim")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
