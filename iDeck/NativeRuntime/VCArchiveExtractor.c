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
#define MAX_NESTED_CABS 48u
#define MAX_NESTED_CAB_BYTES (64u * 1024u * 1024u)
#define MAX_TOTAL_NESTED_BYTES (256u * 1024u * 1024u)

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

/* A PE image of the given machine (0x8664 x64, 0x014c x86). With
 * require_cert, its Authenticode directory must be present and in bounds
 * (presence and bounds only, not trust). */
static int valid_pe(const char *filename, uint16_t machine, int require_cert) {
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
            memcmp(pe, "PE\0\0", 4) || u16(pe + 4) != machine) break;
        /* PE32+ data directories start at optional header + 112, PE32 at + 96. */
        uint16_t magic = u16(pe + 24);
        unsigned directories;
        if (machine == 0x8664 && magic == 0x20b) directories = 112;
        else if (machine == 0x014c && magic == 0x10b) directories = 96;
        else break;
        if (!require_cert) { valid = 1; break; }
        uint32_t directory_count = u32(pe + 24 + directories - 4);
        if (directory_count <= 4) break;
        /* IMAGE_DIRECTORY_ENTRY_SECURITY stores a file offset, not RVA. */
        uint32_t cert_offset = u32(pe + 24 + directories + 4 * 8);
        uint32_t cert_length = u32(pe + 24 + directories + 4 * 8 + 4);
        if (cert_offset == 0 || cert_length < 8 ||
            (uint64_t)cert_offset + cert_length > (uint64_t)st.st_size) break;
        valid = 1;
    } while (0);
    fclose(stream);
    return valid;
}

int ideck_vcrt_valid_pe_x64(const char *filename) {
    return valid_pe(filename, 0x8664, 1);
}

int ideck_vcrt_valid_pe(const char *filename, int machine) {
    return valid_pe(filename, (uint16_t)machine, 0);
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
    /* MSI cabinet names: F_CENTRAL_msvcr100_x86 (2010-2013),
     * FL_msvcr90_dll_... and nosxs_... (2005/2008). */
    static const char *const prefixes[] = { "f_central_", "fl_", "nosxs_" };
    for (size_t p = 0; p < sizeof prefixes / sizeof prefixes[0]; p++) {
        size_t pl = strlen(prefixes[p]);
        if (strncmp(name, prefixes[p], pl)) continue;
        const char *body = name + pl;
        if (!strncmp(body, stem, base_len) &&
            (body[base_len] == '_' || body[base_len] == '-' ||
             body[base_len] == '.' || body[base_len] == '\0')) return 1;
    }
    return 0;
}

#define MAX_WANTED 64

typedef struct {
    const char *const *wanted;
    int count;
    uint16_t machine;
    int require_cert;
    int found[MAX_WANTED];
    unsigned int found_count;
    unsigned int file_count;
    unsigned int nested_count;
    uint64_t total_nested_bytes;
    int saw_cabinet;
} extract_state;

static int nested_candidate(const char *filename) {
    if (!filename) return 0;
    const char *name = filename;
    for (const char *p = filename; *p; p++) {
        if (*p == '/' || *p == '\\') name = p + 1;
    }
    char lower[256];
    size_t length = strlen(name);
    if (!length || length >= sizeof lower) return 0;
    for (size_t i = 0; i < length; i++)
        lower[i] = (char)tolower((unsigned char)name[i]);
    lower[length] = '\0';
    if (length >= 4 &&
        (!strcmp(lower + length - 4, ".cab") ||
         !strcmp(lower + length - 4, ".msi"))) return 1;
    if (length > 1 && (lower[0] == 'a' || lower[0] == 'u')) {
        for (size_t i = 1; i < length; i++)
            if (!isdigit((unsigned char)lower[i])) return 0;
        return 1;
    }
    return 0;
}

static int contains_archive_header(const char *path) {
    FILE *stream = fopen(path, "rb");
    if (!stream) return 0;
    unsigned char bytes[8];
    static const unsigned char compound[8] = {0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1};
    int valid = fread(bytes, 1, sizeof bytes, stream) == sizeof bytes &&
                (memcmp(bytes, "MSCF", 4) == 0 || memcmp(bytes, compound, 8) == 0);
    fclose(stream);
    return valid;
}

/* VC_redist.x64.exe is a WiX bootstrapper: the first CAB often contains
 * files named a10 and a11, each of which is itself a CAB. A single pass
 * through mspack.search(installer) therefore misses all the real DLLs.
 * Recursion is intentionally limited to two nested levels and 48 pieces. */
static int inspect_cabinets(const char *source, const char *target,
                            unsigned level, extract_state *state,
                            char *message, size_t capacity) {
    struct mscab_decompressor *dec = mspack_create_cab_decompressor(NULL);
    if (!dec) {
        error_set(message, capacity, "CAB decompressor unavailable.");
        return -3;
    }
    struct mscabd_cabinet *head = dec->search(dec, source);
    if (!head) {
        mspack_destroy_cab_decompressor(dec);
        return 0;
    }
    state->saw_cabinet = 1;
    int status = 0;
    for (struct mscabd_cabinet *cab = head; cab; cab = cab->next) {
        for (struct mscabd_file *file = cab->files; file; file = file->next) {
            if ((int)state->found_count == state->count) goto finish;
            if (++state->file_count > MAX_FILES_PER_INSTALLER) {
                status = -5;
                error_set(message, capacity, "CAB file count exceeds safety limit.");
                goto finish;
            }
            if (file->length < 512) continue;
            int best = -1;
            size_t longest = 0;
            if ((uint64_t)file->length <= MAX_DLL_SIZE) {
                for (int i = 0; i < state->count; i++) {
                    if (name_match(file->filename, state->wanted[i])) {
                        size_t length = strlen(state->wanted[i]);
                        if (length > longest) { best = i; longest = length; }
                    }
                }
            }
            if (best >= 0 && !state->found[best]) {
                char path[2048];
                if (snprintf(path, sizeof path, "%s/%s", target, state->wanted[best]) >=
                    (int)sizeof path) {
                    status = -6;
                    error_set(message, capacity, "Destination path too long.");
                    goto finish;
                }
                if (dec->extract(dec, file, path) == MSPACK_ERR_OK &&
                    valid_pe(path, state->machine, state->require_cert)) {
                    state->found[best] = 1;
                    state->found_count++;
                } else {
                    unlink(path);
                }
            }
            if (level >= 2 || !nested_candidate(file->filename) ||
                (uint64_t)file->length > MAX_NESTED_CAB_BYTES) continue;
            if (state->nested_count >= MAX_NESTED_CABS ||
                state->total_nested_bytes + (uint64_t)file->length >
                    MAX_TOTAL_NESTED_BYTES) {
                status = -8;
                error_set(message, capacity, "Nested Microsoft CAB limit exceeded.");
                goto finish;
            }
            unsigned serial = ++state->nested_count;
            state->total_nested_bytes += (uint64_t)file->length;
            char nested[2048];
            if (snprintf(nested, sizeof nested, "%s/.ideck-vcrt-cab-%u",
                         target, serial) >= (int)sizeof nested) {
                status = -6;
                error_set(message, capacity, "CAB staging path too long.");
                goto finish;
            }
            if (dec->extract(dec, file, nested) == MSPACK_ERR_OK &&
                contains_archive_header(nested)) {
                /* VC++ 2005 stores its runtime CAB inside an MSI compound file.
                 * search() locates embedded cabinets; the MSI header is not MSCF.
                 * A separate decompressor prevents recursive use of the
                 * same libmspack instance during the outer enumeration. */
                status = inspect_cabinets(nested, target, level + 1,
                                          state, message, capacity);
            }
            unlink(nested);
            if (status) goto finish;
            if ((int)state->found_count == state->count) goto finish;
        }
    }
finish:
    dec->close(dec, head);
    mspack_destroy_cab_decompressor(dec);
    return status;
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
    extract_state state = {0};
    state.wanted = required;
    state.count = DLL_COUNT;
    state.machine = 0x8664;
    state.require_cert = 1;
    int status = inspect_cabinets(installer, target, 0, &state, message, capacity);
    if (status) return status;
    if (!state.saw_cabinet) {
        error_set(message, capacity, "No readable Microsoft CAB archive in installer.");
        return -4;
    }
    for (int i = 0; i < DLL_COUNT; i++) {
        if (!state.found[i]) {
            if (message && capacity) {
                snprintf(message, capacity,
                    "Missing or invalid Microsoft x64 DLL after nested CAB extraction: %s",
                    required[i]);
            }
            return -7;
        }
    }
    error_set(message, capacity, "Extracted all 14 Microsoft x64 DLLs from nested CABs.");
    return 0;
}

int ideck_vcrt_extract_set(const char *installer, const char *target,
                           const char *const *names, int count, int machine,
                           int *found, char *message, size_t capacity) {
    if (!installer || !target || !*installer || !*target || !names ||
        count <= 0 || count > MAX_WANTED || !found) {
        error_set(message, capacity, "Invalid extraction arguments.");
        return -1;
    }
    struct stat dst;
    if (lstat(target, &dst) || !S_ISDIR(dst.st_mode) || (dst.st_mode & 0002)) {
        error_set(message, capacity, "Destination must be a private directory.");
        return -2;
    }
    extract_state state = {0};
    state.wanted = names;
    state.count = count;
    state.machine = (uint16_t)machine;
    int status = inspect_cabinets(installer, target, 0, &state, message, capacity);
    for (int i = 0; i < count; i++) found[i] = state.found[i];
    if (status) return status;
    if (!state.saw_cabinet) {
        error_set(message, capacity, "No readable Microsoft CAB archive in installer.");
        return -4;
    }
    if (message && capacity)
        snprintf(message, capacity, "Extracted %u of %d Microsoft DLLs.", state.found_count, count);
    return (int)state.found_count;
}
