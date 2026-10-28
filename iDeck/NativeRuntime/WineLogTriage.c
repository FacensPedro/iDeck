#include "WineLogTriage.h"
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

enum { WINE_LOG_TAIL_LIMIT = 512 * 1024 };

int32_t ideck_wine_log_diagnose(const char *path) {
    if (!path || !*path) return IDECK_WINE_LOG_NONE;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return IDECK_WINE_LOG_NONE;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0) {
        close(fd);
        return IDECK_WINE_LOG_NONE;
    }
    size_t length = (uint64_t)info.st_size > WINE_LOG_TAIL_LIMIT
        ? WINE_LOG_TAIL_LIMIT : (size_t)info.st_size;
    off_t offset = info.st_size - (off_t)length;
    char *buffer = malloc(length + 1);
    if (!buffer) {
        close(fd);
        return IDECK_WINE_LOG_NONE;
    }
    size_t done = 0;
    while (done < length) {
        ssize_t n = pread(fd, buffer + done, length - done, offset + (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (size_t)n;
    }
    close(fd);
    // Do not copy untrusted log text into the UI: only classify a finite,
    // recent tail and return a fixed error category.
    buffer[done] = '\0';
    for (size_t i = 0; i < done; ++i) {
        if (buffer[i] == '\0') buffer[i] = ' ';
        if (buffer[i] >= 'A' && buffer[i] <= 'Z')
            buffer[i] = (char)(buffer[i] - 'A' + 'a');
    }
    int32_t code = IDECK_WINE_LOG_NONE;
    if (strstr(buffer, "vm_remap failed") ||
        strstr(buffer, "vm_protect(rw) failed") ||
        strstr(buffer, "jit-pool] exhausted") ||
        strstr(buffer, "[ideck wine jit]")) {
        code = IDECK_WINE_LOG_JIT;
    } else if (strstr(buffer, "mprotect errno 13") ||
               strstr(buffer, "executable-permission") ||
               strstr(buffer, "failed to mprotect")) {
        code = IDECK_WINE_LOG_EXEC_PERMISSION;
    } else if (strstr(buffer, "c0000017") ||
               strstr(buffer, "out of memory")) {
        code = IDECK_WINE_LOG_OOM;
    } else if (strstr(buffer, "c0000005") ||
               strstr(buffer, "unhandled page fault") ||
               strstr(buffer, "access violation")) {
        code = IDECK_WINE_LOG_ACCESS_VIOLATION;
    } else if (strstr(buffer, "err:module:import_dll") ||
               strstr(buffer, "failed to load dll")) {
        code = IDECK_WINE_LOG_MISSING_DLL;
    }
    free(buffer);
    return code;
}
