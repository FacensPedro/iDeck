## What's Changed
### Stores
- The initial setup has a Launchers step: it installs the EA app and Ubisoft Connect automatically, without questions. Other Windows installers (.exe) still run with their own windows.
- The EA app and Ubisoft Connect store pages ask for the sign-in instead of the launcher installation: "Sign in in Settings › Stores & launchers".
- Fix "invalid Windows launch request (code 22)" when installing the EA app or Ubisoft Connect: the installers start from Wine's 32-bit command shell, which starts the Windows service manager first, instead of the ARM64 one that iDeck's launcher rejects.

### Version
- Updated the application version to 2.10.5 (build 113).
