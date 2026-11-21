## What's Changed
### Stores
- Run the EA app and Ubisoft Connect installers in an ARM64 session that starts Windows' service manager first, so the EA app installer finds a Windows environment to install into. In 2.10.1 the x64 command shell stopped the service manager and the installer before they started.
- Open an installed EA app or Ubisoft Connect directly again, as before 2.10.1.

### Version
- Updated the application version to 2.10.2 (build 110).
