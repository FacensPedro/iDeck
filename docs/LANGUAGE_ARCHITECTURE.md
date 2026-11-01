# Language architecture

Each layer of iDeck is written in the language that fits it. CI enforces the
boundaries with `scripts/check_language_layers.py`.

| Language | Used for | Where |
|---|---|---|
| **C++** | Intensive processing: emulation glue, the Wine JIT pool (`FEXRuntime.cpp`), graphics translation helpers, download codecs (`EpicChunkCodec.cpp`) | `iDeck/NativeRuntime/*.cpp`, `iDeck/*.cpp` |
| **C** | System components that already use C: zlib/zstd/LZMA codecs, disk I/O, ZIP extraction, LiveContainer init, Wine environment | `iDeck/*.c`, `iDeck/NativeRuntime/*.c` |
| **Swift** | SwiftUI interface and native iOS features (networking, Keychain, Background Tasks, GameController, system frameworks such as Compression and CryptoKit) | `iDeck/*.swift` |
| **Objective-C++** | The only bridge between Swift and C++: an Objective-C class or `extern "C"` API whose header has no C++ types | `iDeck/*.mm`, `iDeck/NativeRuntime/*.mm` |
| **Python** | Build and validation tools outside the app | `scripts/`, `tests/host/` |

## Rules (checked in CI)

1. Swift never sees C++. The bridging header imports only `.h` files, and
   those headers contain no C++ (namespaces, templates, classes, `std::`)
   outside `#ifdef __cplusplus` blocks. Swift's C++ interoperability mode
   stays off.
2. C++ headers are `.hpp` and are included only from `.cpp` and `.mm` files.
3. Every C++ source is reached through Objective-C++ (`.mm`) or an
   `extern "C"` ABI.
4. `.c` files are plain C.
5. Python never ships in the app bundle; it lives in `scripts/` and `tests/`.
6. Hand-written byte loops for decompression, hashing or decoding go to C or
   C++. Swift may call system frameworks (Compression, CryptoKit) directly.

## Example: Epic chunk codec

`EpicChunkCodec.hpp/.cpp` (C++) inflates each downloaded chunk window and
hashes it. `EpicChunkBridge.h/.mm` (Objective-C++) exposes it to Swift as
`IDEpicChunkCodec`, and `EpicFormats.swift` calls that class.
