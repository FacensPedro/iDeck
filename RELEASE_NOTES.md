## What's Changed
### Games
- Fixed Fallout: New Vegas from Epic Games closing about 25 seconds into the game (error 0xC000001D). A read of the game's own memory, made while it reported a message, hit memory that had already been freed; on iOS that fault landed in the middle of a system call and broke its return. The read now goes through the kernel, which reports unreadable memory instead of faulting, and copies whatever is readable, as Windows does.
- DOOM (2016): the game asks for OpenGL 4.5 core, which the OpenGL runtime on iOS does not reach, and stopped with "wglCreateContextAttribsARB failed". iDeck now starts the game's own Vulkan build (DOOMx64vk.exe), which runs on MoltenVK, when it is in the game folder and Vulkan is not turned off for the game.
- Mafia: Definitive Edition (GOG): GOG's play task opened 2K's launcher, which stops with exit code 1 under Wine before the game starts. iDeck now starts the game's own executable. Other GOG games whose play task is only a publisher launcher use another play task of the game, never a setup, settings or uninstall tool.

### EA app
- Dragon Age: Inquisition: the iDeck log now shows all the rows EA's activation window writes, including the reason a licence is refused. Before, only the file's first two rows were kept, so the reason was missing from the bug report.

### Version
- Updated the application version to 3.0.1 (build 130).
