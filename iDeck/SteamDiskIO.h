#ifndef IDECK_STEAM_DISK_IO_H
#define IDECK_STEAM_DISK_IO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Zero on success, otherwise a POSIX errno value. Writes only regular files,
// never follows an attacker-controlled symlink, and retries interrupted I/O.
// If allow_skip_identical is true, identical bytes are not written again.
// actual_written returns bytes submitted to pwrite(), not APFS physical usage.
int ideck_steam_write_chunk(const char *path, const void *data, size_t size,
                            uint64_t offset, int allow_skip_identical,
                            uint64_t *actual_written);
#ifdef __cplusplus
}
#endif
#endif
