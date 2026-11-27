## What's Changed
### Games
- Fixed Fallout: New Vegas from Epic Games closing when Play is tapped in its launcher. After the game's message hook ran, the address of its result was lost, the write faulted and the error handling ran until the stack ran out. The address is now kept safely across the call, as was already done for window messages.

### Version
- Updated the application version to 2.16.4 (build 128).
