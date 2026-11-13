## What's Changed
### EA app
- EA games that refuse their licence and open EA's activation window (ActivationUI.exe), seen with Dragon Age: Inquisition: the licence is bound to a hash of the machine that includes the serial number of drive C:, and on iOS a 64-bit game could not read that serial at all. iDeck's Wine now answers 64-bit programs with the same serial 32-bit programs already got, and the licence is asked for with that serial. The licence is renewed at the next launch.
- The Windows install date in the hash is now read exactly as Wine reads it (the birth time of drive C:'s folder), without rounding.
- Bug reports for EA games now show what the game's activation library did: the licence files it opened, the hardware queries it made, the volume serial and board identity Wine answered with, how ActivationUI.exe was started, the licence files on disk and the last lines of EA's own activation logs. Account tokens and e-mail addresses are removed from those lines.

### Release
- Updated the application version to 2.3.4 (build 76).
