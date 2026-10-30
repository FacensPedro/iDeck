#include <windows.h>
#include <stdio.h>
#include <string.h>

#ifndef IDECK_GUEST_BITS
#define IDECK_GUEST_BITS 64
#endif

int main(void) {
    char directory[MAX_PATH] = {0};
    char filename[MAX_PATH] = {0};
    const DWORD used = GetTempPathA(MAX_PATH, directory);
    if (!used || used >= MAX_PATH) return 21;
    if (snprintf(filename, sizeof(filename), "%sideck-guest-smoke-%u.log",
                 directory, (unsigned)IDECK_GUEST_BITS) >= (int)sizeof(filename)) return 22;
    HANDLE out = CreateFileA(filename, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (out == INVALID_HANDLE_VALUE) return 23;
    char message[256] = {0};
    const int length = snprintf(message, sizeof(message),
        "ideck-guest-smoke=1 arch=%u pid=%lu\r\n",
        (unsigned)IDECK_GUEST_BITS, (unsigned long)GetCurrentProcessId());
    DWORD written = 0;
    const BOOL success = length > 0 && length < (int)sizeof(message) &&
        WriteFile(out, message, (DWORD)length, &written, NULL) &&
        written == (DWORD)length;
    CloseHandle(out);
    if (!success) return 24;
    OutputDebugStringA("[iDeck guest probe] Windows guest executed and wrote a real file");
    fputs(message, stdout);
    fflush(stdout);
    return 0;
}
