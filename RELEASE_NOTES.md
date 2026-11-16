## What's Changed
### Downloads in every store (Steam, GOG, Epic Games, EA app)
- **Pause download** and **Stop download** sit side by side on the game page, with the same fixed size (as do Resume and Stop). Pause keeps the files; Resume continues from them.
- **Stop download** uninstalls the game: it ends the download and removes its files. A first install loses its partial files, and an installed game whose update or repair is stopped is uninstalled.
- A paused or failed download shows **Stop download** next to **Resume**/**Install**, so its files can be removed (Steam also offers **Delete downloaded files**).

### Uninstall
- Steam: the button reports an error instead of doing nothing when the Windows environment is not ready.
- GOG: uninstall compares real paths, so a game whose path goes through /private/var is no longer refused.
- EA app: an installed game with a paused update can be uninstalled.
- EA app and Epic Games: the page closes only when the game was really removed.

### Version
- Updated the application version to 2.7.6 (build 96).
