#!/usr/bin/env python3
"""Publish no Steam identity for programs that are not Steam games.

Madeira's WineProcessBridge publishes a fixed Steam identity (SteamAppId 356400,
Thumper) for every launch that is neither a Madeira Dock session nor a direct
Steam start, so Epic, GOG and plain .exe programs saw SteamAppId/SteamGameId/
SteamAppPath of a game they are not.  A Steamworks game then looks for a Steam
client.  With MADEIRA_NO_STEAM_IDENTITY=1 (set by iDeck's bridge for every
non-Steam launch) none of the three is published.  Idempotent.
"""
import sys
from pathlib import Path

MARKER = "MADEIRA_NO_STEAM_IDENTITY"
ANCHOR = '''        if (dock_session && dock_session[0] == '1') {
            unsetenv("SteamAppPath");'''
NEW = '''        const char *no_steam = getenv("MADEIRA_NO_STEAM_IDENTITY"); /* iDeck: an Epic, GOG or .exe launch */
        if (no_steam && no_steam[0] == '1') {
            unsetenv("SteamAppPath");
            unsetenv("SteamGameId");
            unsetenv("SteamAppId");
            dprintf(STDERR_FILENO, "[steam-env] not a Steam game: no Steam identity published\\n");
        } else if (dock_session && dock_session[0] == '1') {
            unsetenv("SteamAppPath");'''


def main(root: str) -> int:
    path = Path(root) / "app/Madeira/WineProcessBridge.m"
    text = path.read_text()
    if MARKER in text:
        print("Steam identity for non-Steam launches already handled")
        return 0
    if text.count(ANCHOR) != 1:
        print("ERROR: WineProcessBridge.m: no Steam identity anchor", file=sys.stderr)
        return 2
    path.write_text(text.replace(ANCHOR, NEW))
    print("WineProcessBridge.m: non-Steam launches publish no Steam identity")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
