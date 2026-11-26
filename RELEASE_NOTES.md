## What's Changed
### Games
- Fixed Assassin's Creed IV Black Flag and the Epic Games Fallout: New Vegas closing while they create their first window. After the game answered a window message, the address of that message's data was lost, the read faulted and the error handling ran until the stack ran out. The address is now kept safely across the call.
- Fixed BioShock, BioShock 2 and their Remastered editions (Steam and GOG) saying the video card does not meet the minimum requirements. These games now see an NVIDIA card they know.
- Ghostwire Tokyo (and other Direct3D 12 games whose shaders carry their own root signature): compute shaders that the game creates without a separate root signature now use the one inside the shader. Before, they were skipped and the game stopped drawing after its first image.
- Fixed Bully: Scholarship Edition stopping on "Steam Error: Application load error P:0000065434". The game was started without Steam, and its current version needs Steam to start it; it now starts through Steam like other games.

### Runtime (memory, JIT, processes)
- iDeck Virtual Swap (Settings › Graphics & Performance, on by default): game memory and the read parts of x64 programs and DLLs are kept in a file on the device's storage, managed by the Windows runtime's memory manager. Under memory pressure iOS writes those pages to the file and frees the RAM by itself, and reads them back when the game needs them. The file is sized at each launch from the device's RAM and free storage (up to 8 GB, always leaving 4 GB of storage free) and is off when storage is short. Games with their own tuned size keep it.
- JIT: x64 programs and DLLs run from where they are loaded instead of from a second copy in the JIT memory, leaving that memory for compiled code; freed memory blocks are kept for 2 seconds so blocks that come and go are not remapped each time.
- Processes: crash reporters and error-report helpers that games start in the background are no longer started; each was a full Windows process with its own memory.
- iDeck Auto DLL Manager: before a game starts, the DLLs it needs that Wine does not have are looked up by name and architecture (32-bit or 64-bit). DLLs from Microsoft's DirectX runtime (D3DX 9/10/11, the shader compiler, XInput, XAudio2, X3DAudio, XACT) are downloaded once from Microsoft, kept in Files › iDeck › DLL Cache for every game, and copied next to the game's program; the game is checked again and a copy that does not help is taken back. A DLL a failed start asked for is downloaded at once and put in place at the next start. Settings › Windows runtime › Undo automatic DLLs removes them all.

### Game language
- The language no longer appears blank until one is chosen again.
- Only languages the game has are offered: a game with no Portuguese or Spanish (Fallout: New Vegas) no longer lists them. When the store gives no list, English only.
- Choosing another language for an installed Steam game now downloads its dubbing and subtitles.

### Controllers
- The controller API list names each family: Xbox (XInput) for Xbox 360, One and Series; PlayStation (HID) for DualSense and DualShock 4; Nintendo Switch 1 and 2 for Joy-Con and Pro Controllers; and a generic HID controller.
- Joy-Con 2 and the Switch 2 Pro Controller are recognised.
- A DualSense or DualShock 4 connected by cable no longer takes the sound: it keeps playing on the iPhone or iPad.

### JIT
- Built-in JIT: when the device cannot be reached because the loopback VPN is off, iDeck tries again by itself three times and shows "Connect to LocalDevVPN" instead of a connection timeout.

### Epic Games
- Sign-in happens in Safari and connects to iDeck by itself: sign in on Epic's page and iDeck finishes on its own, with no code to copy and paste.

### Downloads
- With more than one game installing, the games after the first show "Waiting" until their turn (Steam, Epic Games, EA app).

### Bugs & logs
- The newest benchmark results are included in the bug report; the Benchmarks button is removed.
- The bug list loads faster: the logs are read in parallel and an unchanged log is not read again.
- Clear logs always works.

### Interface
- Choice lists show "Auto" instead of "Automatic".
- Removed the descriptions under Compatibility, Steam Cloud saves and Epic Cloud saves.
- Epic Games: the Uninstall button shows again on installed games (a save check running in the background hid it).
- MetalFX on a device with less than 8 GB of RAM: "Device not compatible with MetalFX".
- Ubisoft Connect: an expired session shows a short notice above the account.

### Stability
- Fixed iDeck closing while a 32-bit program starts (seen with Tor Browser). A reply from the Windows server could be written to memory that was not mapped in that process; that memory is now checked first, and the program gets an error instead of iDeck closing.

### Version
- Updated the application version to 2.16.2 (build 126).
