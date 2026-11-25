## What's Changed
### Games
- Fixed Assassin's Creed IV Black Flag closing while it creates its first window. After the game answered a window message, the address of that message's data was lost, the read faulted and the error handling ran until the stack ran out. The address is now kept safely across the call.

### Version
- Updated the application version to 2.16.2 (build 126).
