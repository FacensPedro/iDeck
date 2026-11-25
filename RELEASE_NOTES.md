## What's Changed
### Games
- Fixed Assassin's Creed IV Black Flag and the Epic Games Fallout: New Vegas closing while they create their first window. After the game answered a window message, the address of that message's data was lost, the read faulted and the error handling ran until the stack ran out. The address is now kept safely across the call.
- Fixed BioShock, BioShock 2 and their Remastered editions (Steam and GOG) saying the video card does not meet the minimum requirements. These games now see an NVIDIA card they know.
- Ghostwire Tokyo (and other Direct3D 12 games whose shaders carry their own root signature): compute shaders that the game creates without a separate root signature now use the one inside the shader. Before, they were skipped and the game stopped drawing after its first image.

### Game language
- The language no longer appears blank until one is chosen again.
- Only languages the game has are offered: a game with no Portuguese or Spanish (Fallout: New Vegas) no longer lists them. When the store gives no list, English only.
- Choosing another language for an installed Steam game now downloads its dubbing and subtitles.

### Controllers
- The controller API list names each family: Xbox (XInput) for Xbox 360, One and Series; PlayStation (HID) for DualSense and DualShock 4; Nintendo Switch 1 and 2 for Joy-Con and Pro Controllers; and a generic HID controller.
- Joy-Con 2 and the Switch 2 Pro Controller are recognised.
- A DualSense or DualShock 4 connected by cable no longer takes the sound: it keeps playing on the iPhone or iPad.

### JIT
- Built-in JIT: when the device cannot be reached because the loopback VPN is off, iDeck tries again by itself three times, then asks to turn on the VPN in LocalDevVPN or StosVPN instead of showing a connection timeout.

### Downloads
- With more than one game installing, the games after the first show "Waiting" until their turn (Steam, Epic Games, EA app).

### Bugs & logs
- The newest benchmark results are included in the bug report; the Benchmarks button is removed.
- The bug list loads faster: the logs are read in parallel and an unchanged log is not read again.
- Clear logs always works.

### Interface
- Removed the descriptions under Compatibility and Steam Cloud saves.
- Ubisoft Connect: an expired session shows a short notice above the account.

### Stability
- Fixed iDeck closing while a 32-bit program starts (seen with Tor Browser). A reply from the Windows server could be written to memory that was not mapped in that process; that memory is now checked first, and the program gets an error instead of iDeck closing.

### Version
- Updated the application version to 2.16.2 (build 126).
