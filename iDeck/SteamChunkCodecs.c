#include "SteamChunkCodecs.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define STEAM_MAX_CHUNK_SIZE (64u * 1024u * 1024u)
#define ZIP_LOCAL_SIGNATURE UINT32_C(0x04034b50)
#define ZIP_CENTRAL_SIGNATURE UINT32_C(0x02014b50)
#define ZIP_END_SIGNATURE UINT32_C(0x06054b50)

/* Public APIs provided by the pinned PLzmaSDK and libzstd Swift packages. */
typedef struct ISzAlloc ISzAlloc;
typedef const ISzAlloc *ISzAllocPtr;
struct ISzAlloc {
    void *(*Alloc)(ISzAllocPtr allocator, size_t size);
    void (*Free)(ISzAllocPtr allocator, void *address);
};

typedef enum {
    LZMA_FINISH_ANY = 0,
    LZMA_FINISH_END = 1
} ELzmaFinishMode;

typedef enum {
    LZMA_STATUS_NOT_SPECIFIED = 0,
    LZMA_STATUS_FINISHED_WITH_MARK = 1,
    LZMA_STATUS_NOT_FINISHED = 2,
    LZMA_STATUS_NEEDS_MORE_INPUT = 3,
    LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK = 4
} ELzmaStatus;

extern int LzmaDecode(uint8_t *destination, size_t *destination_length,
                      const uint8_t *source, size_t *source_length,
                      const uint8_t *properties, unsigned properties_length,
                      ELzmaFinishMode finish_mode, ELzmaStatus *status,
                      ISzAllocPtr allocator);
extern size_t ZSTD_decompress(void *destination, size_t destination_capacity,
                              const void *source, size_t source_length);
extern unsigned ZSTD_isError(size_t result);

static uint16_t read_le16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | (uint16_t)((uint16_t)bytes[1] << 8);
}

static uint32_t read_le32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static int bounded_region(size_t start, size_t length, size_t bound) {
    return start <= bound && length <= bound - start;
}

static void *lzma_allocate(ISzAllocPtr allocator, size_t size) {
    (void)allocator;
    return malloc(size ? size : 1);
}

static void lzma_release(ISzAllocPtr allocator, void *address) {
    (void)allocator;
    free(address);
}

int32_t lzma_shim_decode(const void *properties, size_t properties_length,
                         const void *source, size_t source_length,
                         void *destination, size_t destination_capacity,
                         size_t *produced) {
    if (produced) *produced = 0;
    if (!properties || properties_length != 5 || !source || !source_length ||
        !destination || !produced || !destination_capacity ||
        destination_capacity > STEAM_MAX_CHUNK_SIZE || properties_length > UINT_MAX) {
        return -1;
    }
    const uint8_t *lzma_properties = properties;
    if (lzma_properties[0] >= 225 || read_le32(lzma_properties + 1) > STEAM_MAX_CHUNK_SIZE) {
        return -1;
    }
    size_t input_used = source_length;
    size_t output_used = destination_capacity;
    ELzmaStatus status = LZMA_STATUS_NOT_SPECIFIED;
    const ISzAlloc allocator = {lzma_allocate, lzma_release};
    const int result = LzmaDecode(destination, &output_used, source, &input_used,
                                  properties, (unsigned)properties_length,
                                  LZMA_FINISH_END, &status, &allocator);
    if (result != 0 || output_used != destination_capacity ||
        (status != LZMA_STATUS_FINISHED_WITH_MARK &&
         status != LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK)) {
        return -1;
    }
    *produced = output_used;
    return 0;
}

intptr_t zstd_safe_decompress(void *destination, size_t destination_capacity,
                              const void *source, size_t source_length) {
    if (!source || !source_length || !destination || !destination_capacity ||
        destination_capacity > STEAM_MAX_CHUNK_SIZE) {
        return -1;
    }
    const size_t length = ZSTD_decompress(destination, destination_capacity,
                                          source, source_length);
    if (ZSTD_isError(length) || length != destination_capacity || length > INTPTR_MAX) {
        return -1;
    }
    return (intptr_t)length;
}

int32_t chunk_zip_decode(const uint8_t *source, size_t source_length,
                         uint8_t *destination, size_t destination_capacity,
                         size_t *produced) {
    if (produced) *produced = 0;
    if (!source || !destination || !produced || source_length < 22 ||
        !destination_capacity || destination_capacity > STEAM_MAX_CHUNK_SIZE ||
        source_length > UINT_MAX || destination_capacity > UINT_MAX) {
        return -1;
    }

    size_t eocd = source_length - 22;
    const size_t earliest = source_length > 65557 ? source_length - 65557 : 0;
    int found = 0;
    for (;;) {
        if (read_le32(source + eocd) == ZIP_END_SIGNATURE &&
            bounded_region(eocd, 22, source_length) &&
            read_le16(source + eocd + 20) == source_length - (eocd + 22)) {
            found = 1;
            break;
        }
        if (eocd == earliest) break;
        --eocd;
    }
    if (!found || read_le16(source + eocd + 4) != 0 ||
        read_le16(source + eocd + 6) != 0 ||
        read_le16(source + eocd + 8) != 1 ||
        read_le16(source + eocd + 10) != 1) {
        return -2;
    }

    const size_t central_size = read_le32(source + eocd + 12);
    const size_t central_start = read_le32(source + eocd + 16);
    if (!bounded_region(central_start, central_size, eocd) ||
        !bounded_region(central_start, 46, eocd) ||
        read_le32(source + central_start) != ZIP_CENTRAL_SIGNATURE) {
        return -3;
    }
    const uint8_t *central = source + central_start;
    const uint16_t flags = read_le16(central + 8);
    const uint16_t method = read_le16(central + 10);
    const uint32_t expected_crc = read_le32(central + 16);
    const size_t compressed_size = read_le32(central + 20);
    const size_t uncompressed_size = read_le32(central + 24);
    const size_t name_length = read_le16(central + 28);
    const size_t extra_length = read_le16(central + 30);
    const size_t comment_length = read_le16(central + 32);
    const uint16_t disk = read_le16(central + 34);
    const size_t local_start = read_le32(central + 42);
    if ((flags & 0x0001) || (flags & 0x0040) || (method != 0 && method != 8) ||
        !name_length || disk || compressed_size == UINT32_MAX ||
        uncompressed_size == UINT32_MAX || local_start == UINT32_MAX ||
        uncompressed_size != destination_capacity ||
        !bounded_region(central_start + 46, name_length + extra_length + comment_length, eocd) ||
        46 + name_length + extra_length + comment_length != central_size ||
        !bounded_region(local_start, 30, central_start) ||
        read_le32(source + local_start) != ZIP_LOCAL_SIGNATURE) {
        return -4;
    }

    const uint8_t *local = source + local_start;
    const uint16_t local_flags = read_le16(local + 6);
    const size_t local_name_length = read_le16(local + 26);
    const size_t local_extra_length = read_le16(local + 28);
    const size_t local_data = local_start + 30 + local_name_length + local_extra_length;
    if (read_le16(local + 8) != method || local_flags != flags ||
        local_name_length != name_length ||
        !bounded_region(local_start + 30, local_name_length + local_extra_length, central_start) ||
        !bounded_region(local_data, compressed_size, central_start) ||
        memcmp(local + 30, central + 46, name_length)) {
        return -5;
    }

    if (method == 0) {
        if (compressed_size != destination_capacity) return -6;
        memcpy(destination, source + local_data, compressed_size);
    } else {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        stream.next_in = (Bytef *)(source + local_data);
        stream.avail_in = (uInt)compressed_size;
        stream.next_out = destination;
        stream.avail_out = (uInt)destination_capacity;
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -7;
        const int result = inflate(&stream, Z_FINISH);
        const size_t output_size = stream.total_out;
        const size_t input_size = stream.total_in;
        inflateEnd(&stream);
        if (result != Z_STREAM_END || output_size != destination_capacity ||
            input_size != compressed_size) return -8;
    }
    const uLong crc = crc32(crc32(0L, Z_NULL, 0), destination,
                            (uInt)destination_capacity);
    if ((uint32_t)crc != expected_crc) return -9;
    *produced = destination_capacity;
    return 0;
}
