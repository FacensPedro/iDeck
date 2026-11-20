## What's Changed
### MetalFX
- MetalFX upscaling and frame generation are now one setting, called MetalFX, with modes: Off, Quality, Performance, Frame generation, and Quality or Performance with frame generation. Quality renders at two thirds of the screen, Performance at half.
- MetalFX is available only on devices with 8 GB of RAM or more; on others it stays off and its setting is disabled.

### Controls
- Joy-Con (Switch 1 and 2) can be used on their own, held sideways: the stick, face buttons, + or - and SL/SR reach the game as an Xbox controller. A Joy-Con pair and the Pro Controller work as before, and iDeck now names them.
- Installers: a tap with the touch mouse clicks again. The cursor is placed on the button before the press, a small drift of the finger no longer cancels the click, and the press is held long enough for the dialog to see it.

### Logs
- Copied Wine logs keep a program's progress lines only once, without the percentage ("Loading" instead of "Loading 1%", "Loading 2%"...).

- Avoid a debug-print exception during 32-bit Direct3D 9 startup without a Windows debugger.
- Report fatal Windows child process exceptions even when the Steam host exits successfully.
- Updated the application version to 2.9.6 (build 107).
