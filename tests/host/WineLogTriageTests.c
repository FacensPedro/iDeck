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
    write_log(path, "Wine failed to mprotect errno 13\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_EXEC_PERMISSION);
    write_log(path, "err:module:import_dll missing foo.dll\n[jit-pool] EXHAUSTED\n");
    assert(ideck_wine_log_diagnose(path) == IDECK_WINE_LOG_JIT);

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
