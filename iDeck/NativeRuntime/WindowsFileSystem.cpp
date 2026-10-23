#include "RuntimeSupport.h"
#include <algorithm>
#include <cctype>
#include <cstring>
#include <string>
#include <vector>
extern "C" bool ideck_windows_to_unix_path(const char *prefix, const char *windows_path, char *output, size_t capacity) {
    if (!prefix || !windows_path || !output || !capacity) return false;
    std::string path(windows_path);
    if (path.size() < 3 || std::tolower(static_cast<unsigned char>(path[0])) != 'c' || path[1] != ':' || (path[2] != '\\' && path[2] != '/')) return false;
    std::replace(path.begin(), path.end(), '\\', '/');
    std::vector<std::string> components;
    size_t start = 3;
    while (start <= path.size()) {
        auto end = path.find('/', start);
        std::string part = path.substr(start, end == std::string::npos ? end : end-start);
        if (part == ".." || part.find(':') != std::string::npos) return false;
        if (!part.empty() && part != ".") components.push_back(part);
        if (end == std::string::npos) break;
        start = end + 1;
    }
    std::string result = std::string(prefix) + "/drive_c";
    for (const auto &part : components) result += "/" + part;
    if (result.size() + 1 > capacity) return false;
    std::memcpy(output, result.c_str(), result.size() + 1);
    return true;
}
