# Native runtime support modules

This change adds ten C/C++/Objective-C++ runtime support sources, a Swift configuration adapter, a C interface header and four upstream build wrappers.

The files are registered in the iDeck Xcode application target. The scripts delegate to the pinned upstream Madeira source tree and fail explicitly when macOS, Xcode or the upstream build entry points are absent.

**Input scope:** DirectInputBridge.mm uses only Apple's GameController discovery API. It does not add mouse handlers, keyboard handlers or Wine mouse/keyboard injection. It does not yet translate controller events into Wine input. Existing project input code is unchanged.

**Implementation scope:** The session module prepares environment and calls the existing guarded runtime preparation API; it cannot launch games until the upstream in-process launcher is completed. The FEX memory adapter allocates memory through the existing native allocator and does not implement the FEX memory map. DLL detection is a file-existence check, not a PE loader. MetalSwapchain configures an existing CAMetalLayer but does not present Wine frames. MetalShaderManager tests the presence of a default Metal library; it does not compile DXMT shaders. WindowsAudioBridge configures AVAudioSession; it does not translate WASAPI. RuntimeErrorHandler records error codes and writes to stderr.

The shell wrappers `build_fex.sh`, `build_wine.sh`, `build_dxmt.sh`, and `build_d3d12.sh` execute existing upstream Madeira scripts if available. They do not independently supply all toolchains, PE libraries, linker settings, or a working IPA. The Wine wrapper covers upstream ntdll-unix only, not the entire Wine runtime.

**Testing:** No Xcode/macOS or on-device compilation has been performed. Upstream scripts may require extra configuration or changes before they succeed. The native launch ABI is still not implemented, so Windows game execution remains unavailable.
