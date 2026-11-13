## What's Changed
### EA app
- Fixed EA games refusing their licence and opening EA's activation window (ActivationUI.exe), seen with Dragon Age: Inquisition. The licence is bound to a hash of the machine that includes the graphics card's PNP id, which the game reads from Wine. Wine gives the id without the instance suffix iDeck assumed, so the game computed a different hash than the one the licence was issued for. iDeck now uses the id exactly as Wine reports it; the licence is renewed with the matching hash at the next launch.

### Release
- Updated the application version to 2.3.2 (build 74).
