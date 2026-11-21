## What's Changed
### Stores
- Fix the EA app installer stopping with "An essential Windows service is not responding" (Windows Installer): iDeck did not recognize Wine's ARM64 command shell, so the installer started without the Windows service manager. The service manager now starts before the EA app and Ubisoft Connect installers.

### Version
- Updated the application version to 2.10.4 (build 112).
