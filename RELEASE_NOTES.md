## What's Changed
### Library
- Game names under the covers are centered.
- The selected store tile on the shelf is no longer cut off at the left edge of the screen.

### Windows runtime
- A game that stops on an illegal instruction (0xC000001D) raised by the Windows runtime's own code is no longer reported as needing AVX/AVX2 translation, and AVX is not turned on for it. The message now says the runtime stopped on an internal error.
