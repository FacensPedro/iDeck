#ifndef IDECK_STEAM_CHUNK_CODECS_H
#define IDECK_STEAM_CHUNK_CODECS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t chunk_zip_decode(const uint8_t *source, size_t source_length,
                         uint8_t *destination, size_t destination_capacity,
                         size_t *produced);

int32_t lzma_shim_decode(const void *properties, size_t properties_length,
                         const void *source, size_t source_length,
                         void *destination, size_t destination_capacity,
                         size_t *produced);

intptr_t zstd_safe_decompress(void *destination, size_t destination_capacity,
                              const void *source, size_t source_length);

#ifdef __cplusplus
}
#endif

#endif
