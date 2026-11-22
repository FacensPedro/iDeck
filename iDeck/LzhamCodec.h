#ifndef IDECK_LZHAM_CODEC_H
#define IDECK_LZHAM_CODEC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decompresses one LZHAM 1.x buffer whole into dst (Vendor/LZHAM, public domain).
///
/// A buffer that starts with LZHAM's zlib header (CMF method 14) is read as a zlib
/// stream: the dictionary size comes from the header and the Adler-32 trailer is
/// checked. Any other buffer is read as a raw LZHAM stream with dict_size_log2.
///
/// Returns the number of bytes written, or a negative lzham_decompress_status_t
/// (-1 for bad arguments).
int64_t ideck_lzham_decompress(const uint8_t *src, size_t src_len,
                               uint8_t *dst, size_t dst_capacity,
                               uint32_t dict_size_log2);

#ifdef __cplusplus
}
#endif

#endif
