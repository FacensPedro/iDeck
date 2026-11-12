## What's Changed
### Windows runtime
- The x64 Windows runtime is now compiled from the same patched Wine as the x86 one: all 386 of its Wine modules, instead of Madeira's prebuilt copies. The Wine Staging and GE-Proton patches and iDeck's own Wine fixes now reach 64-bit games too. Direct3D (DXMT and Madeira's D3D12), FEX and Madeira's own modules are unchanged.
- The DirectShow, Media Foundation and installer modules added in 1.8.2 are now built the way Madeira builds its modules, with their delayed imports linked directly: an x64 delay-load stub can fault when the module runs from the JIT pool.

### Release
- Updated the application version to 1.8.3 (build 65).
