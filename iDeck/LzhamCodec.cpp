// LZHAM decoder for Ubisoft Connect slices (compressionMethod 2).
// The decoder is lzham_codec's lzhamdecomp, copied verbatim into Vendor/LZHAM
// (public domain, richgel999/lzham_codec d379b1f). It is compiled here as one unit,
// so the project lists a single source file for it.
#include "LzhamCodec.h"

#include "Vendor/LZHAM/lzham_assert.cpp"
#include "Vendor/LZHAM/lzham_checksum.cpp"
#include "Vendor/LZHAM/lzham_huffman_codes.cpp"
#include "Vendor/LZHAM/lzham_lzdecompbase.cpp"
#include "Vendor/LZHAM/lzham_lzdecomp.cpp"
#include "Vendor/LZHAM/lzham_mem.cpp"
#include "Vendor/LZHAM/lzham_platform.cpp"
#include "Vendor/LZHAM/lzham_prefix_coding.cpp"
#include "Vendor/LZHAM/lzham_symbol_codec.cpp"
#include "Vendor/LZHAM/lzham_timer.cpp"
#include "Vendor/LZHAM/lzham_vector.cpp"

extern "C" int64_t ideck_lzham_decompress(const uint8_t *src, size_t src_len,
                                          uint8_t *dst, size_t dst_capacity,
                                          uint32_t dict_size_log2) {
    if (!src || !src_len || !dst || !dst_capacity) return -1;

    lzham_decompress_params params;
    memset(&params, 0, sizeof(params));
    params.m_struct_size = sizeof(params);
    params.m_dict_size_log2 = dict_size_log2;
    params.m_table_update_rate = LZHAM_DEFAULT_TABLE_UPDATE_RATE;

    // LZHAM's zlib header: CMF = 14 | (dict_size_log2 - 15) << 4, (CMF*256 + FLG) % 31 == 0.
    if (src_len >= 2 && (src[0] & 15) == LZHAM_Z_LZHAM && ((src[0] << 8) | src[1]) % 31 == 0) {
        params.m_dict_size_log2 = (src[0] >> 4) + LZHAM_MIN_DICT_SIZE_LOG2;
        params.m_decompress_flags = LZHAM_DECOMP_FLAG_READ_ZLIB_STREAM | LZHAM_DECOMP_FLAG_COMPUTE_ADLER32;
    }
    if (params.m_dict_size_log2 < LZHAM_MIN_DICT_SIZE_LOG2 || params.m_dict_size_log2 > LZHAM_MAX_DICT_SIZE_LOG2_X64) return -1;

    size_t written = dst_capacity;
    lzham_uint32 adler = 0;
    lzham_decompress_status_t status = lzham::lzham_lib_decompress_memory(&params, dst, &written, src, src_len, &adler);
    if (status != LZHAM_DECOMP_STATUS_SUCCESS) return -(int64_t)(status ? status : 1);
    return (int64_t)written;
}
