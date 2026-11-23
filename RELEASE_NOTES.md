## What's Changed
### Ubisoft Connect
- Tapping a Ubisoft game now opens its page, as for Steam, GOG, Epic and the EA app. Install, Pause, Stop and Play are on the page, with the download's progress and size.
- Download errors (failed, not signed in, anti-cheat) now appear on the game's page and under its card, as in the other stores, instead of in a pop-up.
- When Ubisoft's download service does not answer, iDeck now tries a second time over IPv4, and the error says why it could not connect (for example a name that did not resolve, a refused connection or a secure-connection problem). Each step is written to iDeck's log. Before, it only said "did not answer (connection)".

### Wine log
- Copying the Wine log is much faster. iDeck now finds the last session from the end of the file and checks each line in place, instead of searching the whole file and converting every line to text.

### Version
- Updated the application version to 2.13.3 (build 121).
