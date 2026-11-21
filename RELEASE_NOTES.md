## What's Changed
### MetalFX
- Combine upscaling and frame generation in one setting with Off, Quality, Performance, Frame generation, and combined modes.
- Disable MetalFX on devices with less than 8 GB of physical memory.

### Controls
- Add standalone sideways Joy-Con support and clearer Nintendo controller names.
- Improve installer touch clicks by moving the pointer before pressing and holding the click long enough for the dialog to receive it.
- Keep an installer tap when Wine refuses to bring its window to the front, which had made buttons such as the EA app's ignore the click, and log where each tap lands.

### Steam
- Before a Steam game starts, ask Steam to end a game this account is playing in another session, as Steam on a PC does, instead of failing with "playing in another session".

### Stores
- Open the EA app and Ubisoft Connect only from their page in Settings, where an Open store button replaces Install once they are installed. Their shortcuts no longer add them next to the stores and games.
- Start Windows' service manager before the EA app and Ubisoft Connect installers and launchers, report Windows 10 to them, and keep the launcher an installer opens running after it closes, so the EA app installer finds a Windows environment to install into.

### Logs
- Compact repeated progress lines in copied Wine logs.

### Version
- Updated the application version to 2.10.0 (build 108).
