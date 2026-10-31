#ifndef IDECK_ZIP_NATIVE_H
#define IDECK_ZIP_NATIVE_H

#include <stddef.h>
#include <stdint.h>

/// Results of the ZIP entry writers.
enum {
    IDECK_ZIP_OK = 0,
    IDECK_ZIP_INVALID = 1,   /* corrupt stream or size mismatch */
    IDECK_ZIP_IO = 2         /* the file could not be written */
};

/// Inflates one raw-deflate ZIP entry (method 8) into an open file.
/// Fails unless exactly `expected_size` bytes come out, so a stream that
/// expands past its declared size (a ZIP bomb) stops at the limit.
int ideck_zip_inflate_to_fd(const uint8_t *src, size_t src_len, int fd, uint64_t expected_size);

/// Writes a stored ZIP entry (method 0) into an open file.
int ideck_zip_write_to_fd(const uint8_t *src, size_t src_len, int fd);

#endif
