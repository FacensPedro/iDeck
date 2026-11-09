## What's Changed
- The initial setup now downloads the x64 and x86 Windows runtime instead of shipping it in the IPA, so the app download is smaller.
- The Windows runtime download retries when GitHub's release servers answer HTTP 502/503/504 or 429, instead of failing with "HTTP 504".
- GOG games come from the GOG Galaxy library and install from their GOG Galaxy builds. The initial setup can install GOG Galaxy 2.0.
- Universal installer environment: MSI, Inno Setup, NSIS, InstallShield, WiX Burn, 7-Zip SFX and Squirrel installers are detected automatically. Visual C++ and .NET (Wine Mono) are installed only when a program needs them.
- Updated the application version to 1.6.3 (build 44).
