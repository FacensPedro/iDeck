#include "EpicChunkCodec.hpp"
#include "PipelineCounters.h"

#include <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include <climits>

namespace ideck::epic {

namespace {
constexpr size_t kMaxWindow = 512u << 20;
}

namespace {
CodecStatus inflateWindowUntimed(const uint8_t *input, size_t inputSize,
                                 uint8_t *out, size_t expectedSize);
}

CodecStatus inflateWindow(const uint8_t *input, size_t inputSize,
                          uint8_t *out, size_t expectedSize) {
    const uint64_t start = ideck_stage_now();
    const CodecStatus status = inflateWindowUntimed(input, inputSize, out, expectedSize);
    ideck_stage_add(IDECK_STAGE_DECOMPRESS, status == CodecStatus::ok ? expectedSize : 0, start);
    return status;
}

namespace {
CodecStatus inflateWindowUntimed(const uint8_t *input, size_t inputSize,
                                 uint8_t *out, size_t expectedSize) {
    if (expectedSize > kMaxWindow) return CodecStatus::tooLarge;
    // RFC 1950 header: CM = 8 (DEFLATE), no preset dictionary, FCHECK valid.
    if (inputSize < 2 || (input[0] & 0x0F) != 8 || (input[1] & 0x20) != 0 ||
        ((static_cast<unsigned>(input[0]) << 8) | input[1]) % 31 != 0)
        return CodecStatus::badHeader;
    if (expectedSize == 0) return CodecStatus::ok;

    z_stream stream {};
    if (inflateInit(&stream) != Z_OK) return CodecStatus::corrupt;
    size_t consumed = 0, produced = 0;
    int result = Z_OK;
    // zlib counts in uInt: feed and drain in pieces for inputs above 4 GiB.
    while (result == Z_OK) {
        const size_t inLeft = inputSize - consumed, outLeft = expectedSize - produced;
        stream.next_in = const_cast<Bytef *>(input + consumed);
        stream.avail_in = static_cast<uInt>(inLeft > UINT_MAX ? UINT_MAX : inLeft);
        stream.next_out = out + produced;
        stream.avail_out = static_cast<uInt>(outLeft > UINT_MAX ? UINT_MAX : outLeft);
        const uInt inBefore = stream.avail_in, outBefore = stream.avail_out;
        result = inflate(&stream, Z_NO_FLUSH);
        consumed += inBefore - stream.avail_in;
        produced += outBefore - stream.avail_out;
        if (result == Z_OK && produced == expectedSize) {
            // Output is full: the stream must end here, not continue.
            uint8_t probe;
            stream.next_out = &probe;
            stream.avail_out = 1;
            result = inflate(&stream, Z_NO_FLUSH);
            if (stream.avail_out == 0) result = Z_DATA_ERROR;
        }
        if (result == Z_OK && inBefore == stream.avail_in && outBefore == stream.avail_out)
            result = Z_BUF_ERROR;
    }
    inflateEnd(&stream);
    return (result == Z_STREAM_END && produced == expectedSize) ? CodecStatus::ok : CodecStatus::corrupt;
}
} // namespace

void sha1(const uint8_t *bytes, size_t size, uint8_t digest[20]) {
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    while (size > 0) {
        const CC_LONG piece = static_cast<CC_LONG>(size > (1u << 30) ? (1u << 30) : size);
        CC_SHA1_Update(&context, bytes, piece);
        bytes += piece;
        size -= piece;
    }
    CC_SHA1_Final(digest, &context);
}

} // namespace ideck::epic
