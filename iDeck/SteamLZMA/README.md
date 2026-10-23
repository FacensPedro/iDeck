# Vendored LZMA decoder

These five files are copied, without functional changes, from the public-domain LZMA decoder included in [7-Zip](https://github.com/ip7z/7zip/tree/26.05/C), release `26.05` (commit `b88c6bc09339de32f7d18bbab900686b244f42ba`):

- `LzmaDec.c`
- `LzmaDec.h`
- `7zTypes.h`
- `Precomp.h`
- `Compiler.h`

The source files identify Igor Pavlov as the author and are marked **Public domain**.

Only `LzmaDec.c` is compiled into the iDeck application target. The C interface in `SteamChunkCodecs.c` calls `LzmaDecode` for Steam's raw LZMA1 chunks using their five-byte properties header and a bounded output buffer.

Vendoring these source files avoids the unsafe build flags in the upstream `PLzmaSDK-Static` Swift package, which Xcode 27 rejects when used as an app target dependency. Zstandard continues to use the separate pinned `facebook/zstd` Swift package.
