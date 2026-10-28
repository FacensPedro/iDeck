#include "VCArchiveExtractor.h"
#include "mspack.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DLL_COUNT 14
#define MAX_DLL_SIZE (32u * 1024u * 1024u)
#define MAX_FILES_PER_INSTALLER 20000u

static const char *const required[DLL_COUNT] = {
    "concrt140.dll", "msvcp140.dll", "msvcp140_1.dll",
    "msvcp140_2.dll", "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll", "vcamp140.dll", "vccorlib140.dll",
    "vcomp140.dll", "vcruntime140.dll", "vcruntime140_1.dll",
    "vcruntime140_threads.dll", "mfc140.dll", "mfc140u.dll"
};

static void error_set(char *message, size_t capacity, const char *why) {
    if (message && capacity) snprintf(message, capacity, "%s", why);
}
static uint16_t u16(const unsigned char *b) {
    return (uint16_t)(b[0] | ((uint16_t)b[1] << 8));
}
static uint32_t u32(const unsigned char *b) {
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
           ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

int ideck_vcrt_valid_pe_x64(const char *filename) {
    if (!filename) return 0;
    FILE *stream = fopen(filename, "rb");
    if (!stream) return 0;
    int valid = 0;
    do {
        struct stat st;
        if (fstat(fileno(stream), &st) || st.st_size < 512 ||
            st.st_size > MAX_DLL_SIZE) break;
        unsigned char mz[64], pe[176];
        if (fread(mz, 1, sizeof mz, stream) != sizeof mz ||
            mz[0] != 'M' || mz[1] != 'Z') break;
        uint32_t offset = u32(mz + 0x3c);
        if (offset < 64 || (uint64_t)offset + sizeof pe > (uint64_t)st.st_size ||
            fseek(stream, (long)offset, SEEK_SET)) break;
        if (fread(pe, 1, sizeof pe, stream) != sizeof pe ||
            memcmp(pe, "PE\0\0", 4) || u16(pe + 4) != 0x8664 ||
            u16(pe + 24) != 0x20b) break;
        /* IMAGE_DIRECTORY_ENTRY_SECURITY stores a file offset, not RVA.
         * This validates presence and bounds, not Authenticode trust.
         */
        uint32_t directory_count = u32(pe + 24 + 108);
        if (directory_count <= 4) break;
        uint32_t cert_offset = u32(pe + 24 + 112 + 4 * 8);
        uint32_t cert_length = u32(pe + 24 + 112 + 4 * 8 + 4);
        if (cert_offset == 0 || cert_length < 8 ||
            (uint64_t)cert_offset + cert_length > (uint64_t)st.st_size) break;
        valid = 1;
    } while (0);
    fclose(stream);
    return valid;
}

static int name_match(const char *filename, const char *wanted) {
    if (!filename || !wanted) return 0;
    const char *tail = filename;
    for (const char *p = filename; *p; p++) {
        if (*p == '/' || *p == '\\') tail = p + 1;
    }
    char name[256], stem[80];
    size_t n = strlen(tail), wn = strlen(wanted);
    if (n == 0 || n >= sizeof name || wn >= sizeof stem) return 0;
    for (size_t i = 0; i < n; i++) name[i] = (char)tolower((unsigned char)tail[i]);
    name[n] = '\0';
    if (!strcmp(name, wanted)) return 1;
    if (!strncmp(name, wanted, wn) &&
        (name[wn] == '_' || name[wn] == '-' || name[wn] == '.')) return 1;
    const char *dot = strstr(wanted, ".dll");
    if (!dot) return 0;
    size_t base_len = (size_t)(dot - wanted);
    memcpy(stem, wanted, base_len);
    stem[base_len] = '\0';
    const char *prefix = "f_central_";
    if (strncmp(name, prefix, strlen(prefix))) return 0;
    const char *body = name + strlen(prefix);
    return !strncmp(body, stem, base_len) &&
           (body[base_len] == '_' || body[base_len] == '-' ||
            body[base_len] == '.' || body[base_len] == '\0');
}

int ideck_vcrt_extract(const char *installer, const char *target,
                       char *message, size_t capacity) {
    if (!installer || !target || !*installer || !*target) {
        error_set(message, capacity, "Invalid extraction arguments.");
        return -1;
    }
    struct stat dst;
    if (lstat(target, &dst) || !S_ISDIR(dst.st_mode) ||
        (dst.st_mode & 0002)) {
        error_set(message, capacity, "Destination must be a private directory.");
        return -2;
    }
    struct mscab_decompressor *decompressor = mspack_create_cab_decompressor(NULL);
    if (!decompressor) {
        error_set(message, capacity, "CAB decompressor unavailable.");
        return -3;
    }
    struct mscabd_cabinet *cabs = decompressor->search(decompressor, installer);
    if (!cabs) {
        mspack_destroy_cab_decompressor(decompressor);
        error_set(message, capacity, "No readable Microsoft CAB archive in installer.");
        return -4;
    }
    int found[DLL_COUNT] = {0};
    unsigned count = 0;
    int result = 0;
    for (struct mscabd_cabinet *cab = cabs; cab; cab = cab->next) {
        for (struct mscabd_file *file = cab->files; file; file = file->next) {
            if (++count > MAX_FILES_PER_INSTALLER) {
                result = -5;
                error_set(message, capacity, "CAB file count exceeds safety limit.");
                goto done;
            }
            if (file->length < 512 || file->length > MAX_DLL_SIZE) continue;
            for (int i = 0; i < DLL_COUNT; i++) {
                if (found[i] || !name_match(file->filename, required[i])) continue;
                char path[2048];
                if (snprintf(path, sizeof path, "%s/%s", target, required[i]) >= (int)sizeof path) {
                    result = -6;
                    error_set(message, capacity, "Destination path too long.");
                    goto done;
                }
                if (decompressor->extract(decompressor, file, path) == MSPACK_ERR_OK &&
                    ideck_vcrt_valid_pe_x64(path)) {
                    found[i] = 1;
                } else {
                    unlink(path);
                }
                break;
            }
        }
    }
    for (int i = 0; i < DLL_COUNT; i++) {
        if (!found[i]) {
            result = -7;
            if (message && capacity)
                snprintf(message, capacity, "Missing or invalid Microsoft x64 DLL: %s", required[i]);
            break;
        }
    }
    if (!result) error_set(message, capacity, "Extracted 14 signed-format x64 DLLs.");
done:
    decompressor->close(decompressor, cabs);
    mspack_destroy_cab_decompressor(decompressor);
    return result;
}
