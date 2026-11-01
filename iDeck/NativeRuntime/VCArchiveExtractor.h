#ifndef IDECK_VC_ARCHIVE_EXTRACTOR_H
#define IDECK_VC_ARCHIVE_EXTRACTOR_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Extracts exactly fourteen allowed Microsoft x64 DLLs from embedded CABs
 * without running a Windows process. target must be a new, empty directory.
 * Returns zero on success; negative values indicate a failed extraction.
 */
int ideck_vcrt_extract(const char *installer, const char *target,
                       char *error_message, size_t error_capacity);
int ideck_vcrt_valid_pe_x64(const char *filename);
/* Extracts any of `names` (lower-case DLL names) found in the installer's
 * nested CABs that are PE images of `machine` (0x014c x86, 0x8664 x64).
 * found[i] is set to 1 for each extracted name. Returns the number of DLLs
 * extracted, or a negative value when the installer is unreadable. */
int ideck_vcrt_extract_set(const char *installer, const char *target,
                           const char *const *names, int count, int machine,
                           int *found, char *error_message, size_t error_capacity);
int ideck_vcrt_valid_pe(const char *filename, int machine);
#ifdef __cplusplus
}
#endif
#endif
