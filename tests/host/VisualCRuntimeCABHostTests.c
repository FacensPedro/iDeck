#include "iDeck/NativeRuntime/VCArchiveExtractor.h"
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 3) return 99;
    char message[512] = {0};
    int result = ideck_vcrt_extract(argv[1], argv[2], message, sizeof message);
    printf("%d %s\n", result, message);
    return result ? 1 : 0;
}
