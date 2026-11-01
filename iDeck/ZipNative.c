// Hot loops of the IPA extractor (PrefixInstaller.swift, ZipExtractor):
// zlib raw inflate and plain writes straight from the memory-mapped archive
// into the destination file, without intermediate Data copies.
#include "ZipNative.h"

#include <errno.h>
#include <unistd.h>
#include <zlib.h>

static int write_all(int fd, const uint8_t *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, bytes, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return IDECK_ZIP_IO;
        }
        bytes += written;
        length -= (size_t)written;
    }
    return IDECK_ZIP_OK;
}

int ideck_zip_write_to_fd(const uint8_t *src, size_t src_len, int fd) {
    if (!src && src_len) return IDECK_ZIP_INVALID;
    return write_all(fd, src, src_len);
}

int ideck_zip_inflate_to_fd(const uint8_t *src, size_t src_len, int fd, uint64_t expected_size) {
    if (expected_size == 0) return IDECK_ZIP_OK;
    if (!src || src_len == 0) return IDECK_ZIP_INVALID;

    enum { CHUNK = 512 * 1024 };
    static __thread uint8_t out[CHUNK];
    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return IDECK_ZIP_INVALID;

    uint64_t produced_total = 0;
    int result = IDECK_ZIP_INVALID;
    const uint8_t *cursor = src;
    size_t remaining = src_len;
    for (;;) {
        if (stream.avail_in == 0 && remaining > 0) {
            uInt take = remaining > 0x40000000u ? 0x40000000u : (uInt)remaining;
            stream.next_in = (Bytef *)cursor;
            stream.avail_in = take;
            cursor += take;
            remaining -= take;
        }
        stream.next_out = out;
        stream.avail_out = CHUNK;
        int status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) break;
        size_t produced = CHUNK - stream.avail_out;
        if (produced) {
            produced_total += produced;
            if (produced_total > expected_size) break;      /* expands past its size */
            if (write_all(fd, out, produced) != IDECK_ZIP_OK) { result = IDECK_ZIP_IO; break; }
        }
        if (status == Z_STREAM_END) {
            result = produced_total == expected_size ? IDECK_ZIP_OK : IDECK_ZIP_INVALID;
            break;
        }
        if (produced == 0 && stream.avail_in == 0 && remaining == 0) break;  /* truncated */
    }
    inflateEnd(&stream);
    return result;
}

int ideck_zip_inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap,
                          size_t *out_len, size_t *consumed) {
    if (out_len) *out_len = 0;
    if (consumed) *consumed = 0;
    if (src_len > UINT32_MAX || dst_cap > UINT32_MAX) return IDECK_ZIP_INVALID;
    z_stream stream = {0};
    if (inflateInit2(&stream, -15) != Z_OK) return IDECK_ZIP_INVALID;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = dst;
    stream.avail_out = (uInt)dst_cap;
    int result = inflate(&stream, Z_FINISH);
    if (out_len) *out_len = (size_t)stream.total_out;
    if (consumed) *consumed = (size_t)stream.total_in;
    inflateEnd(&stream);
    return result == Z_STREAM_END ? IDECK_ZIP_OK : IDECK_ZIP_INVALID;
}
