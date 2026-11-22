#include "LauncherArchiveExtractor.h"
#include "mspack.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define MAX_HEADER_BYTES (64u * 1024u * 1024u)
#define MAX_FILES 50000u
#define MAX_PATH_BYTES 2048

static void fail(char *message, size_t capacity, const char *why) {
    if (message && capacity) snprintf(message, capacity, "%s", why);
}

static uint16_t le16(const unsigned char *b) { return (uint16_t)(b[0] | b[1] << 8); }
static uint32_t le32(const unsigned char *b) {
    return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}

static int read_at(int fd, uint64_t offset, void *buffer, size_t length) {
    unsigned char *out = buffer;
    while (length) {
        ssize_t got = pread(fd, out, length, (off_t)offset);
        if (got <= 0) return -1;
        out += got; offset += (uint64_t)got; length -= (size_t)got;
    }
    return 0;
}

/* Creates every folder of `path` (a file path) under an existing root. */
static int make_parents(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        int ok = mkdir(path, 0755) == 0 || errno == EEXIST;
        *p = '/';
        if (!ok) return -1;
    }
    return 0;
}

/* A relative path from an archive: backslashes become slashes; empty parts,
 * "." and ".." are refused (nothing is written outside the target). */
static int safe_join(char *out, size_t capacity, const char *root, const char *relative) {
    char clean[MAX_PATH_BYTES];
    size_t n = 0;
    const char *part = relative;
    while (*part == '\\' || *part == '/') part++;
    while (*part) {
        const char *end = part;
        while (*end && *end != '\\' && *end != '/') end++;
        size_t length = (size_t)(end - part);
        if (length == 0 || (length == 1 && part[0] == '.') ||
            (length == 2 && part[0] == '.' && part[1] == '.')) return -1;
        for (const char *c = part; c < end; c++) if (*c == ':' || (unsigned char)*c < 0x20) return -1;
        if (n + length + 2 >= sizeof clean) return -1;
        if (n) clean[n++] = '/';
        memcpy(clean + n, part, length);
        n += length;
        part = end;
        while (*part == '\\' || *part == '/') part++;
    }
    if (n == 0) return -1;
    clean[n] = 0;
    return snprintf(out, capacity, "%s/%s", root, clean) < (int)capacity ? 0 : -1;
}

/* ---------------------------------------------------------------- NSIS ---- */

enum { NSIS_CREATEDIR = 11, NSIS_EXTRACTFILE = 20 };
/* $INSTDIR, $OUTDIR and $_OUTDIR: the installation folder. */
#define NSIS_VAR_INSTDIR 21
#define NSIS_VAR_OUTDIR 22
#define NSIS_VAR__OUTDIR 31

typedef struct {
    const unsigned char *header;
    size_t header_size;
    uint32_t strings;
    int unicode;
} nsis_script;

/* A script string as UTF-8. A leading installation-folder variable becomes "",
 * with *rooted set; any other variable, language string or shell folder makes
 * the string unusable (returns -1): the file goes elsewhere ($TEMP, plug-ins). */
static int nsis_string(const nsis_script *s, uint32_t index, char *out, size_t capacity, int *rooted) {
    size_t n = 0;
    *rooted = 0;
    int first = 1;
    if (s->unicode) {
        uint64_t at = (uint64_t)s->strings + (uint64_t)index * 2;
        for (;;) {
            if (at + 2 > s->header_size) return -1;
            uint16_t c = le16(s->header + at); at += 2;
            if (c == 0) break;
            if (c >= 1 && c <= 4) {
                if (at + 2 > s->header_size) return -1;
                uint16_t v = le16(s->header + at); at += 2;
                if (c == 4) { c = v; }
                else if (c == 3) {
                    int var = (v & 0x7f) | (((v >> 8) & 0x7f) << 7);
                    if (first && (var == NSIS_VAR_INSTDIR || var == NSIS_VAR_OUTDIR || var == NSIS_VAR__OUTDIR)) {
                        *rooted = 1; first = 0; continue;
                    }
                    return -1;
                } else return -1;
            }
            first = 0;
            /* UTF-16 to UTF-8 (surrogates are not used in file names here). */
            if (c < 0x80) { if (n + 1 >= capacity) return -1; out[n++] = (char)c; }
            else if (c < 0x800) {
                if (n + 2 >= capacity) return -1;
                out[n++] = (char)(0xC0 | c >> 6); out[n++] = (char)(0x80 | (c & 0x3F));
            } else {
                if (n + 3 >= capacity) return -1;
                out[n++] = (char)(0xE0 | c >> 12); out[n++] = (char)(0x80 | ((c >> 6) & 0x3F));
                out[n++] = (char)(0x80 | (c & 0x3F));
            }
        }
    } else {
        uint64_t at = (uint64_t)s->strings + index;
        for (;;) {
            if (at >= s->header_size) return -1;
            unsigned char c = s->header[at++];
            if (c == 0) break;
            if (c >= 0xFC) {
                if (at + 2 > s->header_size) return -1;
                unsigned char a = s->header[at], b = s->header[at + 1];
                at += 2;
                if (c == 0xFC) { c = a; }
                else if (c == 0xFD) {
                    int var = (a & 0x7f) | ((b & 0x7f) << 7);
                    if (first && (var == NSIS_VAR_INSTDIR || var == NSIS_VAR_OUTDIR || var == NSIS_VAR__OUTDIR)) {
                        *rooted = 1; first = 0; continue;
                    }
                    return -1;
                } else return -1;
            }
            first = 0;
            if (c < 0x80) { if (n + 1 >= capacity) return -1; out[n++] = (char)c; }
            else { if (n + 2 >= capacity) return -1; out[n++] = (char)(0xC0 | c >> 6); out[n++] = (char)(0x80 | (c & 0x3F)); }
        }
    }
    out[n] = 0;
    return 0;
}

/* Inflates (raw deflate) or copies `length` bytes at `offset` into `path`. */
static int nsis_write(int fd, uint64_t offset, uint32_t length, int compressed, const char *path) {
    char temporary[MAX_PATH_BYTES + 16];
    if (snprintf(temporary, sizeof temporary, "%s.ideck-part", path) >= (int)sizeof temporary) return -1;
    int out = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) return -1;
    unsigned char *input = malloc(1 << 20), *output = malloc(1 << 20);
    int status = input && output ? 0 : -1;
    z_stream z;
    memset(&z, 0, sizeof z);
    if (!status && compressed && inflateInit2(&z, -15) != Z_OK) status = -1;
    uint64_t remaining = length;
    int finished = 0;
    while (!status && remaining && !finished) {
        size_t chunk = remaining > (1u << 20) ? (1u << 20) : (size_t)remaining;
        if (read_at(fd, offset, input, chunk)) { status = -1; break; }
        offset += chunk; remaining -= chunk;
        if (!compressed) {
            if (write(out, input, chunk) != (ssize_t)chunk) status = -1;
            continue;
        }
        z.next_in = input; z.avail_in = (uInt)chunk;
        while (z.avail_in && !status) {
            z.next_out = output; z.avail_out = 1u << 20;
            int r = inflate(&z, Z_NO_FLUSH);
            if (r != Z_OK && r != Z_STREAM_END && r != Z_BUF_ERROR) { status = -1; break; }
            size_t produced = (1u << 20) - z.avail_out;
            if (produced && write(out, output, produced) != (ssize_t)produced) { status = -1; break; }
            if (r == Z_STREAM_END) { finished = 1; break; }
            if (r == Z_BUF_ERROR && produced == 0) break;
        }
    }
    /* Flush what the decoder still holds. */
    while (!status && compressed && !finished) {
        z.next_out = output; z.avail_out = 1u << 20;
        int r = inflate(&z, Z_FINISH);
        size_t produced = (1u << 20) - z.avail_out;
        if (produced && write(out, output, produced) != (ssize_t)produced) status = -1;
        if (r == Z_STREAM_END || produced == 0) break;
        if (r != Z_OK && r != Z_BUF_ERROR) status = -1;
    }
    if (compressed) inflateEnd(&z);
    free(input); free(output);
    if (close(out)) status = -1;
    if (!status && rename(temporary, path)) status = -1;
    if (status) unlink(temporary);
    return status;
}

int ideck_nsis_extract(const char *installer, const char *target, char *message, size_t capacity) {
    int fd = open(installer, O_RDONLY);
    if (fd < 0) { fail(message, capacity, "The installer could not be opened."); return -1; }
    struct stat st;
    if (fstat(fd, &st) || st.st_size < 4096) { close(fd); fail(message, capacity, "The installer is not complete."); return -2; }
    uint64_t size = (uint64_t)st.st_size;
    /* The first header sits on a 512-byte boundary after the program. */
    uint64_t first = 0;
    unsigned char probe[28];
    for (uint64_t at = 512; at + 28 <= size && at < (64u << 20); at += 512) {
        if (read_at(fd, at, probe, 28)) break;
        if (le32(probe + 4) == 0xDEADBEEFu && memcmp(probe + 8, "NullsoftInst", 12) == 0) { first = at; break; }
    }
    if (!first) { close(fd); fail(message, capacity, "The installer is not an NSIS installer."); return -3; }
    uint32_t header_size = le32(probe + 20);
    unsigned char word[4];
    if (header_size < 300 || header_size > MAX_HEADER_BYTES || read_at(fd, first + 28, word, 4)) {
        close(fd); fail(message, capacity, "The installer's header is damaged."); return -4;
    }
    uint32_t block = le32(word);
    int compressed = (block & 0x80000000u) != 0;
    block &= 0x7FFFFFFFu;
    if (!compressed && block != header_size) {
        close(fd); fail(message, capacity, "This NSIS installer is solid-compressed, which iDeck cannot open."); return -5;
    }
    if (block > MAX_HEADER_BYTES || first + 32 + block > size) {
        close(fd); fail(message, capacity, "The installer's header is damaged."); return -4;
    }
    unsigned char *raw = malloc(block ? block : 1), *header = malloc(header_size);
    if (!raw || !header || read_at(fd, first + 32, raw, block)) {
        free(raw); free(header); close(fd); fail(message, capacity, "The installer could not be read."); return -6;
    }
    if (compressed) {
        z_stream z;
        memset(&z, 0, sizeof z);
        int ok = inflateInit2(&z, -15) == Z_OK;
        if (ok) {
            z.next_in = raw; z.avail_in = block;
            z.next_out = header; z.avail_out = header_size;
            int r = inflate(&z, Z_FINISH);
            ok = (r == Z_STREAM_END || r == Z_OK || r == Z_BUF_ERROR) && z.avail_out == 0;
            inflateEnd(&z);
        }
        if (!ok) {
            free(raw); free(header); close(fd);
            fail(message, capacity, "This NSIS installer uses a compression iDeck cannot open (only deflate is read).");
            return -7;
        }
    } else {
        memcpy(header, raw, header_size);
    }
    free(raw);
    uint64_t data = first + 32 + block;
    /* Header: flags, then eight (offset, count) blocks: pages, sections,
     * entries, strings, language tables, colours, font, data. */
    uint32_t entries = le32(header + 4 + 8 * 2), entry_count = le32(header + 8 + 8 * 2);
    uint32_t strings = le32(header + 4 + 8 * 3), languages = le32(header + 4 + 8 * 4);
    if (entries >= header_size || strings >= header_size || (uint64_t)entry_count * 28 > header_size - entries ||
        languages < strings || languages > header_size) {
        free(header); close(fd); fail(message, capacity, "The installer's script is damaged."); return -8;
    }
    nsis_script script = { header, languages, strings, 0 };
    /* Unicode installers keep UTF-16 strings: most odd bytes are zero. */
    uint32_t zeros = 0, sample = 0;
    for (uint32_t i = strings + 1; i < languages && sample < 4096; i += 2, sample++) zeros += header[i] == 0;
    script.unicode = sample && zeros * 10 > sample * 6;

    char outdir[MAX_PATH_BYTES] = "";
    int outdir_ok = 0, written = 0;
    char name[MAX_PATH_BYTES], relative[MAX_PATH_BYTES * 2], path[MAX_PATH_BYTES * 3];
    for (uint32_t e = 0; e < entry_count; e++) {
        const unsigned char *entry = header + entries + (uint64_t)e * 28;
        uint32_t which = le32(entry);
        if (which == NSIS_CREATEDIR && le32(entry + 8)) {
            int rooted = 0;
            outdir_ok = nsis_string(&script, le32(entry + 4), outdir, sizeof outdir, &rooted) == 0 && rooted;
            continue;
        }
        if (which != NSIS_EXTRACTFILE) continue;
        int rooted = 0;
        if (nsis_string(&script, le32(entry + 8), name, sizeof name, &rooted)) continue;
        if (rooted) {
            snprintf(relative, sizeof relative, "%s", name);
        } else {
            if (!outdir_ok) continue;
            snprintf(relative, sizeof relative, "%s\\%s", outdir, name);
        }
        if (safe_join(path, sizeof path, target, relative)) continue;
        uint64_t at = data + le32(entry + 12);
        unsigned char length_word[4];
        if (at + 4 > size || read_at(fd, at, length_word, 4)) continue;
        uint32_t length = le32(length_word);
        int deflated = (length & 0x80000000u) != 0;
        length &= 0x7FFFFFFFu;
        if (at + 4 + length > size) continue;
        if (make_parents(path) || nsis_write(fd, at + 4, length, deflated, path)) {
            free(header); close(fd);
            fail(message, capacity, "A file of the installer could not be written. Check the free space.");
            return -9;
        }
        if (++written > (int)MAX_FILES) break;
    }
    free(header);
    close(fd);
    if (!written) { fail(message, capacity, "The installer holds no files for its installation folder."); return -10; }
    return written;
}

/* ----------------------------------------------- Compound file (OLE2) ---- */

typedef struct {
    int fd;
    uint64_t size;
    uint32_t sector_shift, mini_shift, mini_cutoff;
    uint32_t *fat; uint32_t fat_count;
    uint32_t *minifat; uint32_t minifat_count;
    unsigned char *directory; uint32_t directory_count;
    unsigned char *ministream; uint64_t ministream_size;
} cfb;

#define CFB_END 0xFFFFFFFEu

static void cfb_close(cfb *c) {
    free(c->fat); free(c->minifat); free(c->directory); free(c->ministream);
    memset(c, 0, sizeof *c);
}

/* Reads a regular sector chain of `length` bytes (all of it when length is 0
 * and `limit` caps it) into a new buffer. */
static unsigned char *cfb_chain(cfb *c, uint32_t start, uint64_t length, uint64_t *out_length) {
    uint32_t sector_size = 1u << c->sector_shift;
    uint64_t capacity = length ? length : 0;
    if (!length) {
        /* Count the chain first. */
        uint32_t s = start, steps = 0;
        while (s < c->fat_count && steps <= c->fat_count) { capacity += sector_size; s = c->fat[s]; steps++; }
        if (s != CFB_END) return NULL;
    }
    if (capacity > (1ull << 31)) return NULL;
    unsigned char *buffer = malloc(capacity ? capacity : 1);
    if (!buffer) return NULL;
    uint64_t done = 0;
    uint32_t s = start, steps = 0;
    while (done < capacity) {
        if (s >= c->fat_count || steps++ > c->fat_count) { free(buffer); return NULL; }
        uint64_t piece = capacity - done < sector_size ? capacity - done : sector_size;
        if (read_at(c->fd, ((uint64_t)s + 1) << c->sector_shift, buffer + done, (size_t)piece)) { free(buffer); return NULL; }
        done += piece;
        s = c->fat[s];
    }
    if (out_length) *out_length = capacity;
    return buffer;
}

static int cfb_open(cfb *c, const char *path) {
    memset(c, 0, sizeof *c);
    c->fd = open(path, O_RDONLY);
    if (c->fd < 0) return -1;
    struct stat st;
    unsigned char h[512];
    static const unsigned char magic[8] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};
    if (fstat(c->fd, &st) || read_at(c->fd, 0, h, 512) || memcmp(h, magic, 8)) { close(c->fd); return -1; }
    c->size = (uint64_t)st.st_size;
    c->sector_shift = le16(h + 0x1E);
    c->mini_shift = le16(h + 0x20);
    if (c->sector_shift != 9 && c->sector_shift != 12) { close(c->fd); return -1; }
    if (c->mini_shift != 6) { close(c->fd); return -1; }
    uint32_t sector_size = 1u << c->sector_shift;
    uint32_t fat_sectors = le32(h + 0x2C), directory_start = le32(h + 0x30);
    c->mini_cutoff = le32(h + 0x38);
    uint32_t minifat_start = le32(h + 0x3C), minifat_sectors = le32(h + 0x40);
    uint32_t difat_start = le32(h + 0x44), difat_sectors = le32(h + 0x48);
    uint32_t per_sector = sector_size / 4;
    if (fat_sectors == 0 || fat_sectors > (uint32_t)(c->size / sector_size) + 1) { close(c->fd); return -1; }
    /* The FAT's own sectors: 109 in the header, the rest in DIFAT sectors. */
    uint32_t *fat_list = malloc((size_t)fat_sectors * 4);
    if (!fat_list) { close(c->fd); return -1; }
    uint32_t listed = 0;
    for (uint32_t i = 0; i < 109 && listed < fat_sectors; i++) fat_list[listed++] = le32(h + 0x4C + i * 4);
    unsigned char *sector = malloc(sector_size);
    uint32_t next = difat_start;
    for (uint32_t d = 0; d < difat_sectors && listed < fat_sectors && sector; d++) {
        if (read_at(c->fd, ((uint64_t)next + 1) << c->sector_shift, sector, sector_size)) break;
        for (uint32_t i = 0; i + 1 < per_sector && listed < fat_sectors; i++) fat_list[listed++] = le32(sector + i * 4);
        next = le32(sector + (per_sector - 1) * 4);
    }
    int ok = sector && listed == fat_sectors;
    c->fat_count = fat_sectors * per_sector;
    c->fat = ok ? malloc((size_t)c->fat_count * 4) : NULL;
    for (uint32_t i = 0; ok && c->fat && i < fat_sectors; i++) {
        if (read_at(c->fd, ((uint64_t)fat_list[i] + 1) << c->sector_shift, sector, sector_size)) { ok = 0; break; }
        for (uint32_t j = 0; j < per_sector; j++) c->fat[i * per_sector + j] = le32(sector + j * 4);
    }
    free(fat_list); free(sector);
    if (!ok || !c->fat) { close(c->fd); cfb_close(c); return -1; }
    uint64_t directory_bytes = 0;
    c->directory = cfb_chain(c, directory_start, 0, &directory_bytes);
    if (!c->directory) { close(c->fd); cfb_close(c); return -1; }
    c->directory_count = (uint32_t)(directory_bytes / 128);
    if (minifat_sectors) {
        uint64_t minifat_bytes = 0;
        unsigned char *raw = cfb_chain(c, minifat_start, 0, &minifat_bytes);
        if (!raw) { close(c->fd); cfb_close(c); return -1; }
        c->minifat_count = (uint32_t)(minifat_bytes / 4);
        c->minifat = malloc((size_t)c->minifat_count * 4 + 4);
        for (uint32_t i = 0; c->minifat && i < c->minifat_count; i++) c->minifat[i] = le32(raw + i * 4);
        free(raw);
        /* The root entry's stream holds every small stream. */
        const unsigned char *root = c->directory;
        uint64_t root_size = le32(root + 120);
        if (root_size) c->ministream = cfb_chain(c, le32(root + 116), root_size, &c->ministream_size);
    }
    return 0;
}

/* MSI stream names are packed: two name characters per UTF-16 unit. */
static int msi_decode_name(const unsigned char *utf16, int units, char *out, size_t capacity) {
    static const char alphabet[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._";
    size_t n = 0;
    for (int i = 0; i < units; i++) {
        uint16_t c = le16(utf16 + i * 2);
        if (c == 0) break;
        if (n + 3 >= capacity) return -1;
        if (c >= 0x3800 && c < 0x4800) {
            c -= 0x3800;
            out[n++] = alphabet[c & 0x3F];
            out[n++] = alphabet[(c >> 6) & 0x3F];
        } else if (c >= 0x4800 && c < 0x4840) {
            out[n++] = alphabet[c - 0x4800];
        } else if (c == 0x4840) {
            out[n++] = '!';
        } else if (c < 0x80) {
            out[n++] = (char)c;
        } else {
            out[n++] = '?';
        }
    }
    out[n] = 0;
    return 0;
}

/* The directory entry of a stream named `name` (decoded), or -1. */
static int cfb_find(cfb *c, const char *name) {
    char decoded[128];
    for (uint32_t i = 0; i < c->directory_count; i++) {
        const unsigned char *d = c->directory + (uint64_t)i * 128;
        if (d[66] != 2) continue;  /* streams only */
        int units = le16(d + 64) / 2;
        if (units < 1 || units > 32) continue;
        if (msi_decode_name(d, units, decoded, sizeof decoded)) continue;
        if (strcmp(decoded, name) == 0) return (int)i;
    }
    return -1;
}

static uint64_t cfb_stream_size(cfb *c, int entry) {
    const unsigned char *d = c->directory + (uint64_t)entry * 128;
    uint64_t size = le32(d + 120);
    if (c->sector_shift == 12) size |= (uint64_t)le32(d + 124) << 32;
    return size;
}

/* A whole stream in memory (small and table streams). */
static unsigned char *cfb_read(cfb *c, int entry, uint64_t *length) {
    const unsigned char *d = c->directory + (uint64_t)entry * 128;
    uint64_t size = cfb_stream_size(c, entry);
    uint32_t start = le32(d + 116);
    *length = size;
    if (size >= c->mini_cutoff) return cfb_chain(c, start, size, NULL);
    unsigned char *buffer = malloc(size ? size : 1);
    if (!buffer) return NULL;
    uint64_t done = 0;
    uint32_t s = start, steps = 0;
    while (done < size) {
        if (s >= c->minifat_count || steps++ > c->minifat_count || !c->ministream) { free(buffer); return NULL; }
        uint64_t at = (uint64_t)s << c->mini_shift, piece = size - done < 64 ? size - done : 64;
        if (at + piece > c->ministream_size) { free(buffer); return NULL; }
        memcpy(buffer + done, c->ministream + at, piece);
        done += piece;
        s = c->minifat[s];
    }
    return buffer;
}

/* Copies a large stream (a cabinet) to a file, sector by sector. */
static int cfb_copy(cfb *c, int entry, const char *path) {
    const unsigned char *d = c->directory + (uint64_t)entry * 128;
    uint64_t size = cfb_stream_size(c, entry);
    if (size < c->mini_cutoff) {
        uint64_t length = 0;
        unsigned char *small = cfb_read(c, entry, &length);
        if (!small) return -1;
        FILE *f = fopen(path, "wb");
        int ok = f && fwrite(small, 1, length, f) == length;
        if (f && fclose(f)) ok = 0;
        free(small);
        return ok ? 0 : -1;
    }
    int out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out < 0) return -1;
    uint32_t sector_size = 1u << c->sector_shift;
    unsigned char *buffer = malloc(sector_size);
    uint64_t done = 0;
    uint32_t s = le32(d + 116), steps = 0;
    int status = buffer ? 0 : -1;
    while (!status && done < size) {
        if (s >= c->fat_count || steps++ > c->fat_count) { status = -1; break; }
        uint64_t piece = size - done < sector_size ? size - done : sector_size;
        if (read_at(c->fd, ((uint64_t)s + 1) << c->sector_shift, buffer, (size_t)piece) ||
            write(out, buffer, (size_t)piece) != (ssize_t)piece) { status = -1; break; }
        done += piece;
        s = c->fat[s];
    }
    free(buffer);
    if (close(out)) status = -1;
    return status;
}

/* ----------------------------------------------------- MSI database ---- */

typedef struct {
    char **values;     /* string id -> UTF-8 (NULL for empty) */
    uint32_t count;
    int reference_size;
} msi_strings;

static void msi_strings_free(msi_strings *s) {
    for (uint32_t i = 0; i < s->count; i++) free(s->values[i]);
    free(s->values);
    memset(s, 0, sizeof *s);
}

static char *latin1_to_utf8(const unsigned char *bytes, size_t length, int utf8) {
    char *out = malloc(length * 2 + 1);
    if (!out) return NULL;
    size_t n = 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = bytes[i];
        if (c < 0x80 || utf8) out[n++] = (char)c;
        else { out[n++] = (char)(0xC0 | c >> 6); out[n++] = (char)(0x80 | (c & 0x3F)); }
    }
    out[n] = 0;
    return out;
}

static int msi_load_strings(cfb *c, msi_strings *s) {
    memset(s, 0, sizeof *s);
    int pool_entry = cfb_find(c, "!_StringPool"), data_entry = cfb_find(c, "!_StringData");
    if (pool_entry < 0 || data_entry < 0) return -1;
    uint64_t pool_size = 0, data_size = 0;
    unsigned char *pool = cfb_read(c, pool_entry, &pool_size);
    unsigned char *data = cfb_read(c, data_entry, &data_size);
    if (!pool || !data || pool_size < 4) { free(pool); free(data); return -1; }
    uint32_t codepage = le16(pool) | (uint32_t)(le16(pool + 2) & 0x7FFF) << 16;
    s->reference_size = (le16(pool + 2) & 0x8000) ? 3 : 2;
    uint32_t pairs = (uint32_t)(pool_size / 4);
    s->values = calloc(pairs + 1, sizeof(char *));
    if (!s->values) { free(pool); free(data); return -1; }
    uint64_t offset = 0;
    uint32_t n = 1;
    for (uint32_t i = 1; i < pairs;) {
        uint32_t length = le16(pool + i * 4);
        uint32_t references = le16(pool + i * 4 + 2);
        if (length == 0 && references == 0) { i++; n++; continue; }
        if (length == 0) {
            if (i + 1 >= pairs) break;
            length = (uint32_t)le16(pool + i * 4 + 6) << 16 | le16(pool + i * 4 + 4);
            i += 2;
        } else {
            i += 1;
        }
        if (offset + length > data_size) break;
        if (n <= pairs) s->values[n] = latin1_to_utf8(data + offset, length, codepage == 65001);
        offset += length;
        n++;
    }
    s->count = pairs + 1;
    free(pool); free(data);
    return 0;
}

static const char *msi_string(const msi_strings *s, uint32_t id) {
    return id && id < s->count && s->values[id] ? s->values[id] : "";
}

#define MSI_COLUMNS_MAX 32
typedef struct {
    int columns;
    int width[MSI_COLUMNS_MAX];
    int is_string[MSI_COLUMNS_MAX];
    char name[MSI_COLUMNS_MAX][64];
    uint32_t rows;
    unsigned char *data;
    uint64_t column_offset[MSI_COLUMNS_MAX];
} msi_table;

static void msi_table_free(msi_table *t) { free(t->data); memset(t, 0, sizeof *t); }

static uint32_t msi_cell(const msi_table *t, uint32_t row, int column) {
    const unsigned char *p = t->data + t->column_offset[column] + (uint64_t)row * t->width[column];
    switch (t->width[column]) {
    case 2: return t->is_string[column] ? le16(p) : (uint32_t)(le16(p) ^ 0x8000);
    case 3: return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16;
    default: return t->is_string[column] ? le32(p) : le32(p) ^ 0x80000000u;
    }
}

static int msi_column(const msi_table *t, const char *name) {
    for (int i = 0; i < t->columns; i++) if (strcmp(t->name[i], name) == 0) return i;
    return -1;
}

/* A table's layout from _Columns (Table, Number, Name, Type), then its rows. */
static int msi_load_table(cfb *c, const msi_strings *s, const char *table, msi_table *t) {
    memset(t, 0, sizeof *t);
    int columns_entry = cfb_find(c, "!_Columns");
    if (columns_entry < 0) return -1;
    uint64_t size = 0;
    unsigned char *raw = cfb_read(c, columns_entry, &size);
    if (!raw) return -1;
    int r = s->reference_size, row_size = r + 2 + r + 2;
    uint32_t rows = (uint32_t)(size / (uint64_t)row_size);
    msi_table meta = {0};
    meta.columns = 4; meta.rows = rows; meta.data = raw;
    int widths[4] = {r, 2, r, 2}, strings[4] = {1, 0, 1, 0};
    uint64_t at = 0;
    for (int i = 0; i < 4; i++) { meta.width[i] = widths[i]; meta.is_string[i] = strings[i]; meta.column_offset[i] = at; at += (uint64_t)widths[i] * rows; }
    for (uint32_t row = 0; row < rows; row++) {
        if (strcmp(msi_string(s, msi_cell(&meta, row, 0)), table)) continue;
        uint32_t number = msi_cell(&meta, row, 1);
        uint32_t type = msi_cell(&meta, row, 3);
        if (number < 1 || number > MSI_COLUMNS_MAX) continue;
        int index = (int)number - 1;
        if (type & 0x4000) continue;  /* temporary: not stored */
        snprintf(t->name[index], sizeof t->name[index], "%s", msi_string(s, msi_cell(&meta, row, 2)));
        t->is_string[index] = (type & 0x0800) != 0;
        t->width[index] = t->is_string[index] ? r : ((type & 0xFF) <= 2 ? 2 : 4);
        if (index + 1 > t->columns) t->columns = index + 1;
    }
    free(raw);
    if (!t->columns) return -1;
    int row_bytes = 0;
    for (int i = 0; i < t->columns; i++) { if (!t->width[i]) return -1; row_bytes += t->width[i]; }
    char stream[80];
    snprintf(stream, sizeof stream, "!%s", table);
    int entry = cfb_find(c, stream);
    if (entry < 0) { t->rows = 0; t->data = malloc(1); return t->data ? 0 : -1; }
    t->data = cfb_read(c, entry, &size);
    if (!t->data) return -1;
    t->rows = (uint32_t)(size / (uint64_t)row_bytes);
    at = 0;
    for (int i = 0; i < t->columns; i++) { t->column_offset[i] = at; at += (uint64_t)t->width[i] * t->rows; }
    return 0;
}

/* DefaultDir "target:source", each "short|long": the target's long name. */
static void msi_long_name(const char *value, char *out, size_t capacity) {
    char buffer[512];
    snprintf(buffer, sizeof buffer, "%s", value);
    char *colon = strchr(buffer, ':');
    if (colon) *colon = 0;
    char *bar = strchr(buffer, '|');
    snprintf(out, capacity, "%s", bar ? bar + 1 : buffer);
}

typedef struct {
    msi_table directory;
    const msi_strings *strings;
    int key, parent, default_dir;
} msi_directories;

/* The folder of a Directory key relative to drive_c, or -1 when it is not under
 * a folder iDeck installs into. */
static int msi_directory_path(const msi_directories *d, uint32_t key_id, char *out, size_t capacity, int depth) {
    const char *key = msi_string(d->strings, key_id);
    static const struct { const char *property, *path; } roots[] = {
        {"ProgramFiles64Folder", "Program Files"}, {"ProgramFilesFolder", "Program Files (x86)"},
        {"CommonFiles64Folder", "Program Files/Common Files"}, {"CommonFilesFolder", "Program Files (x86)/Common Files"},
        {"WindowsFolder", "windows"}, {"System64Folder", "windows/system32"}, {"SystemFolder", "windows/syswow64"},
        {"CommonAppDataFolder", "ProgramData"},
    };
    for (size_t i = 0; i < sizeof roots / sizeof roots[0]; i++) {
        if (strcmp(key, roots[i].property) == 0) { snprintf(out, capacity, "%s", roots[i].path); return 0; }
    }
    if (depth > 32) return -1;
    for (uint32_t row = 0; row < d->directory.rows; row++) {
        if (msi_cell(&d->directory, row, d->key) != key_id) continue;
        uint32_t parent = msi_cell(&d->directory, row, d->parent);
        char name[512];
        msi_long_name(msi_string(d->strings, msi_cell(&d->directory, row, d->default_dir)), name, sizeof name);
        if (!parent || parent == key_id) return -1;  /* TARGETDIR or another root: not a known folder */
        char base[MAX_PATH_BYTES];
        if (msi_directory_path(d, parent, base, sizeof base, depth + 1)) return -1;
        if (strcmp(name, ".") == 0 || name[0] == 0) snprintf(out, capacity, "%s", base);
        else if (snprintf(out, capacity, "%s/%s", base, name) >= (int)capacity) return -1;
        return 0;
    }
    return -1;
}

int ideck_msi_extract(const char *package, const char *target, char *message, size_t capacity) {
    cfb c;
    if (cfb_open(&c, package)) { fail(message, capacity, "The package is not a Windows Installer package."); return -1; }
    msi_strings strings;
    msi_table files = {0}, components = {0}, media = {0};
    msi_directories dirs = {0};
    int status = 0, written = 0;
    char cab_path[MAX_PATH_BYTES] = "";
    struct mscab_decompressor *decoder = NULL;
    struct mscabd_cabinet *cabinet = NULL;
    if (msi_load_strings(&c, &strings)) { close(c.fd); cfb_close(&c); fail(message, capacity, "The package's strings could not be read."); return -2; }
    dirs.strings = &strings;
    if (msi_load_table(&c, &strings, "File", &files) || msi_load_table(&c, &strings, "Component", &components) ||
        msi_load_table(&c, &strings, "Directory", &dirs.directory) || msi_load_table(&c, &strings, "Media", &media)) {
        status = -3; fail(message, capacity, "The package's tables could not be read."); goto done;
    }
    int file_key = msi_column(&files, "File"), file_component = msi_column(&files, "Component_"),
        file_name = msi_column(&files, "FileName");
    int component_key = msi_column(&components, "Component"), component_dir = msi_column(&components, "Directory_");
    dirs.key = msi_column(&dirs.directory, "Directory");
    dirs.parent = msi_column(&dirs.directory, "Directory_Parent");
    dirs.default_dir = msi_column(&dirs.directory, "DefaultDir");
    int media_cabinet = msi_column(&media, "Cabinet");
    if (file_key < 0 || file_component < 0 || file_name < 0 || component_key < 0 || component_dir < 0 ||
        dirs.key < 0 || dirs.parent < 0 || dirs.default_dir < 0 || media_cabinet < 0) {
        status = -3; fail(message, capacity, "The package's tables are not the expected ones."); goto done;
    }
    decoder = mspack_create_cab_decompressor(NULL);
    if (!decoder) { status = -4; fail(message, capacity, "CAB decompressor unavailable."); goto done; }
    for (uint32_t m = 0; m < media.rows && !status; m++) {
        const char *cab = msi_string(&strings, msi_cell(&media, m, media_cabinet));
        if (!cab[0]) continue;
        if (cab[0] != '#') { status = -5; fail(message, capacity, "The package keeps its files outside it, which iDeck cannot install."); break; }
        int entry = cfb_find(&c, cab + 1);
        if (entry < 0) { status = -5; fail(message, capacity, "The package's cabinet is missing."); break; }
        snprintf(cab_path, sizeof cab_path, "%s/.ideck-msi-%u.cab", target, m);
        if (cfb_copy(&c, entry, cab_path)) { status = -6; fail(message, capacity, "The package's cabinet could not be copied. Check the free space."); break; }
        cabinet = decoder->open(decoder, cab_path);
        if (!cabinet) { status = -7; fail(message, capacity, "The package's cabinet could not be opened."); break; }
        for (struct mscabd_file *file = cabinet->files; file && !status; file = file->next) {
            /* A cabinet file is named by its File key. */
            uint32_t row = 0;
            int found = 0;
            for (; row < files.rows; row++) {
                if (strcmp(msi_string(&strings, msi_cell(&files, row, file_key)), file->filename) == 0) { found = 1; break; }
            }
            if (!found) continue;
            uint32_t component = msi_cell(&files, row, file_component);
            uint32_t directory = 0;
            for (uint32_t k = 0; k < components.rows; k++) {
                if (msi_cell(&components, k, component_key) == component) { directory = msi_cell(&components, k, component_dir); break; }
            }
            char folder[MAX_PATH_BYTES], name[512], relative[MAX_PATH_BYTES * 2], path[MAX_PATH_BYTES * 3];
            if (!directory || msi_directory_path(&dirs, directory, folder, sizeof folder, 0)) continue;
            msi_long_name(msi_string(&strings, msi_cell(&files, row, file_name)), name, sizeof name);
            snprintf(relative, sizeof relative, "%s/%s", folder, name);
            if (safe_join(path, sizeof path, target, relative) || make_parents(path)) continue;
            if (decoder->extract(decoder, file, path) != MSPACK_ERR_OK) {
                status = -8; fail(message, capacity, "A file of the package could not be written. Check the free space.");
                break;
            }
            if (++written > (int)MAX_FILES) break;
        }
        decoder->close(decoder, cabinet);
        cabinet = NULL;
        unlink(cab_path);
    }
    if (!status && !written) { status = -9; fail(message, capacity, "The package holds no files iDeck can install."); }
done:
    if (decoder) mspack_destroy_cab_decompressor(decoder);
    msi_table_free(&files); msi_table_free(&components); msi_table_free(&dirs.directory); msi_table_free(&media);
    msi_strings_free(&strings);
    close(c.fd);
    cfb_close(&c);
    return status ? status : written;
}

/* ------------------------------------------------------ Burn bundle ---- */

int ideck_burn_manifest(const char *bundle, const char *output, char *message, size_t capacity) {
    struct mscab_decompressor *decoder = mspack_create_cab_decompressor(NULL);
    if (!decoder) { fail(message, capacity, "CAB decompressor unavailable."); return -1; }
    struct mscabd_cabinet *head = decoder->search(decoder, bundle);
    int status = -2;
    for (struct mscabd_cabinet *cab = head; cab && status; cab = cab->next) {
        for (struct mscabd_file *file = cab->files; file; file = file->next) {
            /* The Burn manifest is the UX container's file "0". */
            if (strcmp(file->filename, "0") || file->length > (16u << 20)) continue;
            status = decoder->extract(decoder, file, output) == MSPACK_ERR_OK ? 0 : -3;
            break;
        }
    }
    if (head) decoder->close(decoder, head);
    mspack_destroy_cab_decompressor(decoder);
    if (status) fail(message, capacity, "The installer's manifest could not be read.");
    return status;
}
