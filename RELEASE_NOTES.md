## What's Changed
### EA app
- Fixed EA games refusing their licence and opening EA's activation window (ActivationUI.exe), seen with Dragon Age: Inquisition. The licence is bound to a hash of the machine that includes the processor's feature flags, and the flags iDeck hashed did not match what the x86 emulator (FEX) reports to the game: one bit (Self Snoop) differed, so the game computed a different hash than the one the licence was issued for. iDeck now uses FEX's exact values; the licence is renewed with the matching hash at the next launch.
- The board and BIOS manufacturer and the board serial number in the hash are now read from the device the same way Wine reads them, instead of being assumed.
- Games with the newest activation libraries hash the graphics card's full PNP id again; 2.3.2 had cut it short for them as well.
- Bug reports for EA games now show the exact text the licence hash was built from (a device serial number is never shown) and the local EA service's activity.

### Release
- Updated the application version to 2.3.3 (build 75).
