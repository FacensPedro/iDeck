#include "RuntimeSupport.h"
#include <cstring>
#include <initializer_list>
#include <string>
#include <sys/stat.h>
extern "C" bool ideck_wine_dll_exists(const char *root, const char *name) {
    if (!root || !name || !*root || !*name) return false;
    std::string dll(name);
    if (dll.find('/') != std::string::npos || dll.find('\\') != std::string::npos || dll.find("..") != std::string::npos) return false;
    std::string base(root);
    if (base.empty() || base.size() > 4096) return false;
    for (const char *folder : {"/drive_c/windows/system32/", "/drive_c/windows/syswow64/"}) {
        std::string path = base + folder + dll;
        struct stat st {};
        if (stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode)) return true;
    }
    return false;
}
