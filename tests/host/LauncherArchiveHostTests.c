/* Host check of the launcher extractors: LauncherArchiveHostTests <nsis|msi|burn> <file> <target> */
#include "iDeck/NativeRuntime/LauncherArchiveExtractor.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 4) return 99;
    char message[512] = {0};
    int result = strcmp(argv[1], "nsis") == 0 ? ideck_nsis_extract(argv[2], argv[3], message, sizeof message)
               : strcmp(argv[1], "msi") == 0 ? ideck_msi_extract(argv[2], argv[3], message, sizeof message)
               : ideck_burn_manifest(argv[2], argv[3], message, sizeof message);
    printf("%d %s\n", result, message);
    return result < 0 ? 1 : 0;
}
