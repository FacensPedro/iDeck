#include "SteamDiskIO.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int matches_existing(int fd, const uint8_t *bytes,
                            size_t length, off_t offset) {
    uint8_t scratch[65536];
    size_t pos = 0;
    while (pos < length) {
        size_t request = length - pos;
        if (request > sizeof(scratch)) request = sizeof(scratch);
        ssize_t count = pread(fd, scratch, request, offset + (off_t)pos);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || (size_t)count != request) return 0;
        for (size_t i = 0; i < request; ++i) {
            if (scratch[i] != bytes[pos + i]) return 0;
        }
        pos += request;
    }
    return 1;
}

int ideck_steam_write_chunk(const char *path, const void *data, size_t size,
                            uint64_t offset, int allow_skip_identical,
                            uint64_t *actual_written) {
    if (actual_written) *actual_written = 0;
    if (!path || !*path || (!data && size) ||
        offset > INT64_MAX || size > (size_t)(INT64_MAX - offset))
        return EINVAL;
    int flags = O_WRONLY | O_NOFOLLOW;
    if (allow_skip_identical) flags = O_RDWR | O_NOFOLLOW;
    int fd = open(path, flags);
    if (fd < 0) return errno;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        int err = errno ? errno : EINVAL;
        close(fd);
        return err;
    }
    const uint8_t *bytes = (const uint8_t *)data;
    if (allow_skip_identical && matches_existing(fd, bytes, size, (off_t)offset)) {
        close(fd);
        return 0;
    }
    size_t written = 0;
    while (written < size) {
        ssize_t n = pwrite(fd, bytes + written, size - written,
                           (off_t)offset + (off_t)written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            int err = n < 0 ? errno : EIO;
            if (actual_written) *actual_written = (uint64_t)written;
            close(fd);
            return err;
        }
        written += (size_t)n;
    }
    if (actual_written) *actual_written = (uint64_t)written;
    if (close(fd) != 0) return errno;
    return 0;
}
