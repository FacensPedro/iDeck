## What's Changed
### Windows runtime
- The Direct3D companion stand-ins announced in 2.3.6 (d3d11on12, d3d9on12, d3dcsx_42, d3dcsx_43) were not actually in the app: their sources were left out of the repository, and the build skipped them with a warning. They are now built into the 32-bit and 64-bit runtimes.

### First-time setup
- The Visual C++ step no longer lists the Windows environment (x64 + x86) as a separate item or says where the download comes from. The environment is still prepared by the same Install button.

### Release
- Updated the application version to 2.4.1 (build 80).
