## What's Changed
### Downloads
- Epic Games downloads fetch 24 chunks ahead of the writer instead of 8.
- EA app downloads fetch 8 files and 12 ranges of a large file at once, over up to 32 connections.
- Pausing an EA app download no longer throws away the large file in progress: its finished ranges are kept and the download continues from them. A resumed download keeps the progress it showed.
- GOG, Epic Games and EA app game pages show how much is on the device while installing ("Installed: 1.2 GB / 4 GB"), as Steam's page does.

### Library
- Long game names wrap to a second line instead of ending in "...". Every title takes two lines, so all cards are the same size.
- Covers of games that are not installed are less blurred.
- The buttons under each game in the library (Launch, Resume, installing, pause and stop) are gone. Tap a game to open its page, where these controls are.
- Store and game tiles on the shelf show artwork only: no caption under them and no download bar over them.
- The "Game Library" heading and installed count under the iDeck title are gone.

### Starting games
- Starting an Epic Games or EA app game opens StikDebug at once, while the store's launch token is fetched, instead of after it.

### Settings and notifications
- iRelay support is removed, along with its Settings entry. Steam, GOG, Epic Games and EA app games download on the device.
- After "Don't Allow" on the notification prompt, iDeck shows no notification at all, including the system's download activity. Downloads then continue in the background only for the short period iOS grants.
- "Run first-time setup again" is now a "Setup assistant" row in the style of the other settings.
- In Bugs & logs, the Bugs and JIT groups start collapsed.

### Fixes
- Vulkan could not start since the runtime moved out of the IPA ("Failed to load MADEIRA_VULKAN_LIBRARY"): MoltenVK was looked up in the downloaded runtime, but it is in the app. This affected Vulkan games and the DXVK and vkd3d options.
- A cancelled GOG install is no longer logged as a redistributable failure.

- Updated the application version to 1.7.0 (build 52).
