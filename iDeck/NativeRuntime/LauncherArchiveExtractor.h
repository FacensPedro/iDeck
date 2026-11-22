#ifndef IDECK_LAUNCHER_ARCHIVE_EXTRACTOR_H
#define IDECK_LAUNCHER_ARCHIVE_EXTRACTOR_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* The EA app and Ubisoft Connect installed without Wine: their installers are
 * opened on the device and their files copied, no Windows program runs.
 *
 * ideck_nsis_extract: the files an NSIS 3 installer (Ubisoft Connect) puts in
 * its installation folder ($INSTDIR), written under `target` with their
 * folders. Only uncompressed and deflate (non-solid) installers are read.
 *
 * ideck_msi_extract: the files of a Windows Installer package whose cabinets
 * are inside it (the EA app), written under `target` as drive_c would hold them
 * ("Program Files/Electronic Arts/..."). Files under folders other than the
 * Program Files, Windows and ProgramData folders are left out.
 *
 * ideck_burn_manifest: the manifest (XML) of a WiX Burn bundle (the EA app's
 * EAappInstaller.exe), written to `output`. It names the package to download.
 *
 * Each returns the number of files written (0 for the manifest on success),
 * or a negative value with the reason in `error_message`. */
int ideck_nsis_extract(const char *installer, const char *target,
                       char *error_message, size_t error_capacity);
int ideck_msi_extract(const char *package, const char *target,
                      char *error_message, size_t error_capacity);
int ideck_burn_manifest(const char *bundle, const char *output,
                        char *error_message, size_t error_capacity);
#ifdef __cplusplus
}
#endif
#endif
