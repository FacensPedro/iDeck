#ifndef IDECK_WINDOWS_PE_MACHINE_H
#define IDECK_WINDOWS_PE_MACHINE_H

#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>

#define IDECK_PE_I386 0x014Cu
#define IDECK_PE_AMD64 0x8664u

static inline uint16_t ideck_pe_machine_from_file(const char *path) {
    if (!path || !*path) return 0;
    FILE *file = fopen(path, "rb");
    if (!file) return 0;

    uint16_t machine = 0;
    struct stat info;
    unsigned char dos[64];
    unsigned char pe[26];
    if (fstat(fileno(file), &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_size < 90 ||
        fread(dos, 1, sizeof(dos), file) != sizeof(dos) ||
        dos[0] != 'M' || dos[1] != 'Z')
        goto done;

    uint32_t offset = (uint32_t)dos[0x3c] |
                      ((uint32_t)dos[0x3d] << 8) |
                      ((uint32_t)dos[0x3e] << 16) |
                      ((uint32_t)dos[0x3f] << 24);
    if (offset < 64 || offset > 64u * 1024u * 1024u ||
        (uint64_t)offset + sizeof(pe) > (uint64_t)info.st_size ||
        fseeko(file, (off_t)offset, SEEK_SET) != 0 ||
        fread(pe, 1, sizeof(pe), file) != sizeof(pe) ||
        pe[0] != 'P' || pe[1] != 'E' || pe[2] != 0 || pe[3] != 0)
        goto done;

    uint16_t cpu = (uint16_t)(pe[4] | ((uint16_t)pe[5] << 8));
    uint16_t optional_size = (uint16_t)(pe[20] | ((uint16_t)pe[21] << 8));
    uint16_t magic = (uint16_t)(pe[24] | ((uint16_t)pe[25] << 8));
    if ((cpu == IDECK_PE_I386 && magic == 0x10Bu && optional_size >= 96) ||
        (cpu == IDECK_PE_AMD64 && magic == 0x20Bu && optional_size >= 112)) {
        if ((uint64_t)offset + 24u + optional_size <= (uint64_t)info.st_size)
            machine = cpu;
    }

done:
    fclose(file);
    return machine;
}

#endif
