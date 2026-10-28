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
#ifdef __cplusplus
}
#endif
#endif
