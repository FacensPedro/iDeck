## What's Changed
### EA app
- The bug report has an "EA hash check" line for EA games. It compares the machine values iDeck signs the licence with (board and BIOS maker, Windows product id, C: volume serial, graphics card, processor) with what the game reads from the Windows environment (the prefix registry and volume serial), and names the fields that differ. A licence the game refuses, which makes it open EA's activation window, can then be traced to the field that does not match.

### Release
- Updated the application version to 2.3.1 (build 73).
