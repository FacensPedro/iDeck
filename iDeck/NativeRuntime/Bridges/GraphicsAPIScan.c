#include "GraphicsAPIScan.h"

#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define SCAN_WINDOW (4u * 1024u * 1024u)

static const struct { const char *name; uint32_t bit; } kDLLs[] = {
    {"d3d9.dll", IDECK_API_D3D9},       {"d3d10.dll", IDECK_API_D3D10},
    {"d3d10_1.dll", IDECK_API_D3D10},   {"d3d10core.dll", IDECK_API_D3D10},
    {"d3d11.dll", IDECK_API_D3D11},     {"d3d12.dll", IDECK_API_D3D12},
    {"d3d12core.dll", IDECK_API_D3D12}, {"dxgi.dll", IDECK_API_DXGI},
    {"vulkan-1.dll", IDECK_API_VULKAN}, {"opengl32.dll", IDECK_API_OPENGL},
};
#define DLL_COUNT (sizeof(kDLLs) / sizeof(kDLLs[0]))

static unsigned char lower(unsigned char c) { return (c >= 'A' && c <= 'Z') ? (unsigned char)(c + 32) : c; }

static uint32_t read32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t read16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

/* The API bit for a DLL name (case-insensitive, NUL-terminated within `max`). */
static uint32_t api_for_name(const uint8_t *name, size_t max) {
    char folded[32];
    size_t n = 0;
    while (n < max && n < sizeof(folded) - 1 && name[n]) { folded[n] = (char)lower(name[n]); ++n; }
    if (n == max || n == sizeof(folded) - 1) return 0;
    folded[n] = 0;
    for (size_t i = 0; i < DLL_COUNT; ++i)
        if (strcmp(folded, kDLLs[i].name) == 0) return kDLLs[i].bit;
    return 0;
}

/* File offset of a relative virtual address, through the section table. */
static int rva_to_offset(const uint8_t *base, size_t size, const uint8_t *sections, unsigned count,
                         uint32_t rva, size_t *offset) {
    for (unsigned i = 0; i < count; ++i) {
        const uint8_t *s = sections + (size_t)i * 40;
        if ((size_t)(s - base) + 40 > size) return 0;
        const uint32_t va = read32(s + 12), vsize = read32(s + 8), raw = read32(s + 20), rsize = read32(s + 16);
        const uint32_t span = vsize > rsize ? vsize : rsize;
        if (rva >= va && rva - va < span && rva - va < rsize) {
            const size_t at = (size_t)raw + (rva - va);
            if (at >= size) return 0;
            *offset = at;
            return 1;
        }
    }
    return 0;
}

/* APIs named in the import (directory 1) and delay-import (directory 13) tables. */
static uint32_t static_imports(const uint8_t *base, size_t size) {
    if (size < 0x40 || base[0] != 'M' || base[1] != 'Z') return 0;
    const uint32_t pe = read32(base + 0x3c);
    if (pe > size - 24 || memcmp(base + pe, "PE\0\0", 4) != 0) return 0;
    const unsigned sections = read16(base + pe + 6);
    const uint16_t optional_size = read16(base + pe + 20);
    const uint8_t *optional = base + pe + 24;
    if ((size_t)(optional - base) + optional_size > size || optional_size < 2) return 0;
    const uint16_t magic = read16(optional);
    const size_t directories = magic == 0x20b ? 112 : magic == 0x10b ? 96 : 0;
    if (!directories || optional_size < directories + 14 * 8) return 0;
    const uint8_t *section_table = optional + optional_size;
    uint32_t found = 0;
    for (int which = 0; which < 2; ++which) {
        const unsigned index = which == 0 ? 1 : 13;
        const uint8_t *dir = optional + directories + index * 8;
        const uint32_t rva = read32(dir), length = read32(dir + 4);
        size_t at;
        if (!rva || !length || !rva_to_offset(base, size, section_table, sections, rva, &at)) continue;
        const size_t entry = which == 0 ? 20 : 32;          /* IMAGE_IMPORT_DESCRIPTOR / delay descriptor */
        const size_t name_field = which == 0 ? 12 : 4;
        for (unsigned n = 0; n < 4096 && at + entry <= size; ++n, at += entry) {
            const uint32_t name_rva = read32(base + at + name_field);
            if (!name_rva) break;
            size_t name_at;
            if (rva_to_offset(base, size, section_table, sections, name_rva, &name_at))
                found |= api_for_name(base + name_at, size - name_at);
        }
    }
    return found;
}

/* DLL names as ASCII or UTF-16 text anywhere in [start, end). */
static uint32_t text_references(const uint8_t *p, size_t start, size_t end) {
    uint32_t found = 0;
    for (size_t i = 0; i < DLL_COUNT; ++i) {
        const char *name = kDLLs[i].name;
        const size_t len = strlen(name);
        if (found & kDLLs[i].bit) continue;
        for (size_t at = start; at + len <= end; ++at) {
            if (lower(p[at]) != (unsigned char)name[0]) continue;
            size_t k = 1;
            while (k < len && at + k < end && lower(p[at + k]) == (unsigned char)name[k]) ++k;
            if (k == len) { found |= kDLLs[i].bit; break; }
            if (at + len * 2 <= end) {
                k = 0;
                while (k < len && lower(p[at + 2 * k]) == (unsigned char)name[k] && p[at + 2 * k + 1] == 0) ++k;
                if (k == len) { found |= kDLLs[i].bit; break; }
            }
        }
    }
    return found;
}

uint32_t ideck_pe_graphics_apis(const char *path) {
    if (!path) return 0;
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 64) { close(fd); return 0; }
    const size_t size = (size_t)info.st_size;
    const uint8_t *base = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return 0;
    const uint32_t imported = static_imports(base, size);
    uint32_t text = text_references(base, 0, size < SCAN_WINDOW ? size : SCAN_WINDOW);
    if (size > SCAN_WINDOW)
        text |= text_references(base, size > 2 * SCAN_WINDOW ? size - SCAN_WINDOW : SCAN_WINDOW, size);
    munmap((void *)base, size);
    return imported | text | (imported << IDECK_API_STATIC_SHIFT);
}
