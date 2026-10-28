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
    // Some iDeck logs append multiple Wine sessions. Never attribute an
    // error in a prior launch to a subsequent healthy launch when both are
    // present in the scanned tail. If this session grew beyond 512 KiB, the
    // tail remains bounded and we only classify evidence still in the tail.
    const char *current_session = buffer;
    const char *next_session = buffer;
    const char *session_marker = "[wineserver-bridge] ws_log test";
    while ((next_session = strstr(next_session, session_marker)) != NULL) {
        current_session = next_session;
        next_session += strlen(session_marker);
    }
    int32_t code = IDECK_WINE_LOG_NONE;
    if (strstr(current_session, "[wow-window] main-process reserve failed") &&
        strstr(current_session, "c0000017")) {
        code = IDECK_WINE_LOG_WOW64_ADDRESS_SPACE;
    } else if (strstr(current_session, "[x18-decline]") &&
               (strstr(current_session, "[mach_exc] unhandled") ||
                strstr(current_session, "code=c000001d"))) {
        code = IDECK_WINE_LOG_ARM64EC_EXCEPTION;
    } else if (strstr(current_session, "vm_remap failed") ||
        strstr(current_session, "vm_protect(rw) failed") ||
        strstr(current_session, "jit-pool] exhausted") ||
        strstr(current_session, "[ideck wine jit]")) {
        code = IDECK_WINE_LOG_JIT;
    } else if (strstr(current_session, "mprotect errno 13") ||
               strstr(current_session, "executable-permission")) {
        code = IDECK_WINE_LOG_EXEC_PERMISSION;
    } else if (strstr(current_session, "c0000017") ||
               strstr(current_session, "out of memory")) {
        code = IDECK_WINE_LOG_OOM;
    } else if (strstr(current_session, "c0000005") ||
               strstr(current_session, "unhandled page fault") ||
               strstr(current_session, "access violation")) {
        code = IDECK_WINE_LOG_ACCESS_VIOLATION;
    } else if (strstr(current_session, "err:module:import_dll") ||
               strstr(current_session, "failed to load dll")) {
        code = IDECK_WINE_LOG_MISSING_DLL;
    }
    free(buffer);
    return code;
}
