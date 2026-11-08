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
               (strstr(current_session, "code=c000001d") ||
                (strstr(current_session, "[mach_exc] unhandled") &&
                 !strstr(current_session, "c0000005")))) {
        // Only report the x18/0xC000001D finding when the status really is
        // 0xC000001D; an x18 decline followed by an access violation is a
        // different failure (see the stale-IAT and AV branches below).
        code = IDECK_WINE_LOG_ARM64EC_EXCEPTION;
    } else if (strstr(current_session, "[ec-bind]") &&
               strstr(current_session, "pool stale") &&
               (strstr(current_session, "c0000005") ||
                strstr(current_session, "unhandled page fault"))) {
        // A stale function pointer in the JIT pool is concrete evidence of a
        // synchronization discrepancy. It can coexist with a guest AV; this
        // classification does NOT prove it caused that exception.
        code = IDECK_WINE_LOG_ARM64EC_STALE_IAT_FAULT;
    } else if (strstr(current_session, "wineserver failed to start") ||
               strstr(current_session, "wineserver timeout") ||
               strstr(current_session, "wineserver unexpectedly exited") ||
               strstr(current_session, "wineserver connection refused")) {
        code = IDECK_WINE_LOG_WINESERVER;
    } else if (strstr(current_session, "dxmt] failed") ||
               strstr(current_session, "d3d12] failed") ||
               strstr(current_session, "metal presentation failed") ||
               strstr(current_session, "shader compilation failed") ||
               strstr(current_session, "no drawable available")) {
        code = IDECK_WINE_LOG_GRAPHICS;
    } else if (strstr(current_session, "c000001d") ||
               strstr(current_session, "illegal instruction") ||
               strstr(current_session, "unsupported instruction")) {
        code = IDECK_WINE_LOG_UNSUPPORTED_INSTRUCTION;
    } else if (strstr(current_session, "usbmux timeout") ||
               strstr(current_session, "ideck is not listening") ||
               strstr(current_session, "irelay connection failed")) {
        code = IDECK_WINE_LOG_IRELAY;
    } else if (strstr(current_session, "checksum mismatch") ||
               strstr(current_session, "hash verification failed") ||
               strstr(current_session, "download integrity failed")) {
        code = IDECK_WINE_LOG_DOWNLOAD_INTEGRITY;
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

// The Wine host may return exit code 0 even after its Steam-launched child
// pseudo-process aborted with STATUS_ACCESS_VIOLATION. Read only bytes logged
// after the active launch began: earlier game crashes must not poison a later
// successful exit. We require abort_process rather than a handled SEH fault.
int32_t ideck_wine_log_fatal_av_since(const char *path, int64_t start_offset) {
    if (!path || !*path || start_offset < 0) return 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 0;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0) {
        close(fd);
        return 0;
    }
    // If Madeira truncated the previous log when opening the new session,
    // inspect the new log from its beginning.
    off_t start = (off_t)start_offset;
    if (start > info.st_size) start = 0;
    off_t floor = info.st_size > WINE_LOG_TAIL_LIMIT
        ? info.st_size - WINE_LOG_TAIL_LIMIT : 0;
    if (start < floor) start = floor;
    size_t length = (size_t)(info.st_size - start);
    if (!length) { close(fd); return 0; }
    char *buffer = malloc(length + 1);
    if (!buffer) { close(fd); return 0; }
    size_t done = 0;
    while (done < length) {
        ssize_t n = pread(fd, buffer + done, length - done, start + (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (size_t)n;
    }
    close(fd);
    buffer[done] = '\0';
    for (size_t i = 0; i < done; ++i) {
        if (buffer[i] == '\0') buffer[i] = ' ';
        if (buffer[i] >= 'A' && buffer[i] <= 'Z')
            buffer[i] = (char)(buffer[i] - 'A' + 'a');
    }
    // The Steam Dock host can exit successfully while the launched game dies.
    // Ignore merely handled exceptions and diagnostics from older sessions.
    const char *current = buffer;
    const char *marker = "[wineserver-bridge] ws_log test";
    const char *next = buffer;
    while ((next = strstr(next, marker)) != NULL) {
        current = next;
        next += strlen(marker);
    }
    int32_t found = strstr(current, "abort_process: status=0xc0000005") != NULL;
    free(buffer);
    return found;
}
