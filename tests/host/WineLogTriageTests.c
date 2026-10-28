#include "../../iDeck/NativeRuntime/WineLogTriage.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void write_log(const char *path, const char *message) {
    FILE *f = fopen(path, "wb");
    assert(f);
    assert(fwrite(message, 1, strlen(message), f) == strlen(message));
    assert(fclose(f) == 0);
}

int main(void) {
    char dir[] = "/tmp/ideck-wine-diagnosis-XXXXXX";
    assert(mkdtemp(dir));
    char path[512], alias[512];
    assert(snprintf(path, sizeof(path), "%s/madeira-log.txt", dir) > 0);
    assert(snprintf(alias, sizeof(alias), "%s/log-symlink", dir) > 0);
    assert(ideck_wine_log_diagnose(NULL) == IDECK_WINE_LOG_NONE);
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_NONE);

    write_log(path, "Info: Wine launched\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_NONE);
    write_log(path, "[iDeck Wine JIT] vm_remap failed size=268435456 kr=3\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_JIT);
    write_log(path, "err:module:import_dll Library foo.dll not found\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_MISSING_DLL);
    write_log(path, "Unhandled page fault on write access to 0x00000000\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_ACCESS_VIOLATION);
    write_log(path, "FATAL NTSTATUS c0000017 out of memory\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_OOM);
    write_log(path, "Failed to mprotect last page of code buffer\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_NONE);
    write_log(path, "Wine failed to mprotect errno 13\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_EXEC_PERMISSION);
    write_log(path, "err:module:import_dll missing foo.dll\n[jit-pool] EXHAUSTED\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_JIT);

    // A 32-bit Windows installer can fail before its entry point when
    // iPadOS cannot reserve the minimum WoW64 guest window.
    write_log(path,
        "[wineserver-bridge] ws_log test - log file set up OK\\n"
        "[wow-window] refused: map too small (5792 MB free VA)\\n"
        "[wow-window] main-process reserve FAILED 0xc0000017\\n"
        "[Wine ntdll] FATAL: no WoW64 guest window\\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_WOW64_ADDRESS_SPACE);

    // Cuphead reaches Wine/FEX, then its native ARM64EC exception handler
    // declines a broken x18 frame and reports NTSTATUS C000001D. A benign
    // FEX mprotect warning must not be treated as the root cause.
    write_log(path,
        "[wineserver-bridge] ws_log test - log file set up OK\\n"
        "E 24 Failed to mprotect last page of code buffer.\\n"
        "[x18-decline] pc=0x18f3731e8 x18=0 teb=0x717ffe0000\\n"
        "[mach_exc] UNHANDLED #1 type=6 x18=0x0\\n"
        "[exc-disp] raise tid=0024 code=c000001d\\n"
        "[wine-exit] Windows program stopped (Wine exit code 1)\\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_ARM64EC_EXCEPTION);

    // The append-only Wine log can include several sessions. Only diagnose
    // the latest session marker; otherwise an earlier crash would appear
    // as the reason a later, healthy launch failed.
    write_log(path,
        "[wineserver-bridge] ws_log test first session\\n"
        "[x18-decline] x18=0\\n"
        "[exc-disp] raise code=c000001d\\n"
        "[wineserver-bridge] ws_log test new session\\n"
        "[WineProc] process started successfully\\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_NONE);

    write_log(path,
        "[wineserver-bridge] ws_log test first session\\n"
        "[wow-window] main-process reserve FAILED 0xc0000017\\n"
        "[wineserver-bridge] ws_log test second session\\n"
        "err:module:import_dll Library game.dll not found\\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_MISSING_DLL);

    // Only the bounded tail is scanned, so ancient errors do not override
    // a later healthy session after the log becomes very large.
    FILE *file = fopen(path, "wb");
    assert(file);
    assert(fputs("[iDeck Wine JIT] old failure\n", file) > 0);
    char *padding = malloc(600 * 1024);
    assert(padding);
    memset(padding, 'X', 600 * 1024);
    assert(fwrite(padding, 1, 600 * 1024, file) == 600 * 1024);
    assert(fputs("err:module:import_dll new failure\n", file) > 0);
    assert(fclose(file) == 0);
    free(padding);
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_MISSING_DLL);

    assert(symlink(path, alias) == 0);
    assert(ideck_wine_log_diagnose(alias) == IDECK_WINE_LOG_NONE);
    assert(unlink(alias) == 0);
    assert(unlink(path) == 0);
    assert(rmdir(dir) == 0);
    puts("PASS: bounded Madeira Wine log triage, evidence priority and symlink rejection");
    return 0;
}
