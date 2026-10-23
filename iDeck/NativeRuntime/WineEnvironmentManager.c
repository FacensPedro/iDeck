#include "RuntimeSupport.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
int32_t ideck_wine_environment_configure(const char *prefix) {
    if (!prefix || !*prefix || strlen(prefix) > 4096) return EINVAL;
    struct stat st;
    if (stat(prefix, &st) != 0 || !S_ISDIR(st.st_mode)) return ENOENT;
    if (setenv("WINEPREFIX", prefix, 1) != 0) return errno;
    if (setenv("WINEARCH", "win64", 1) != 0) return errno;
    if (setenv("WINEDEBUG", "-all", 1) != 0) return errno;
    return 0;
}
