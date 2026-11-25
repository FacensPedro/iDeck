## What's Changed
### Games
- Fixed Assassin's Creed IV Black Flag closing while it creates its first window. After the game answered a window message, the address of that message's data was lost, the read faulted and the error handling ran until the stack ran out. The address is now kept safely across the call.

- Fixed BioShock, BioShock 2 and their Remastered editions (Steam and GOG) saying the video card does not meet the minimum requirements. These games now see an NVIDIA card they know.

### Stability
- Fixed iDeck closing while a 32-bit program starts (seen with Tor Browser). A reply from the Windows server could be written to memory that was not mapped in that process; that memory is now checked first, and the program gets an error instead of iDeck closing.

### Version
- Updated the application version to 2.16.2 (build 126).
