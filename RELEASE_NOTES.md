## What's Changed
- Pause download works at once for EA and Epic games, from iDeck and from iRelay. EA downloads no longer pile up gigabytes in memory while a file is unpacked, which made iOS close iDeck.
- iRelay connection: the iDeck service keeps listening when iOS suspends iDeck (for example while StikDebug enables JIT), and iDeck's listeners restart when it returns to the foreground.
- The iRelay pairing code is now 4 digits. Pair again in iRelay 3.7.4 with the new code.
- Settings › iRelay no longer shows the iDeck service row.
- Updated the application version to 1.2.6 (build 24).
