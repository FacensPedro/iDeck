// Epic Games chunk window processing (C++ core). Called only through the
// Objective-C++ bridge in EpicChunkBridge.mm; Swift never includes this file.
#pragma once

#include <cstddef>
#include <cstdint>

namespace ideck::epic {

enum class CodecStatus : int {
    ok = 0,
    badHeader = 1,     // not a zlib stream with a DEFLATE method
    corrupt = 2,       // inflate failed or produced a different size
    tooLarge = 3,      // window above the 512 MiB format limit
};

/// Inflates a zlib (RFC 1950) stream into `out`, which holds exactly
/// `expectedSize` bytes. Succeeds only when the stream ends at that size.
CodecStatus inflateWindow(const uint8_t *input, size_t inputSize,
                          uint8_t *out, size_t expectedSize);

/// SHA-1 of `size` bytes into `digest[20]`.
void sha1(const uint8_t *bytes, size_t size, uint8_t digest[20]);

} // namespace ideck::epic
