#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#include <cerrno>
#include <sys/stat.h>
extern "C" int32_t ideck_runtime_prepare(const char *wine_prefix) {
    if (!wine_prefix || !*wine_prefix) return EINVAL;
    struct stat info {};
    if (stat(wine_prefix, &info) != 0 || !S_ISDIR(info.st_mode)) return ENOENT;
    if (!ideck_metal_available() || !ideck_fex_available() ||
        !ideck_wineserver_available() || !ideck_wineprocess_available()) return ENOSYS;
    if (!ideck_fex_initialize()) return EAGAIN;
    if (!ideck_wineserver_initialize()) return EAGAIN;
    return 0;
}
extern "C" int32_t ideck_runtime_launch(const char *executable_path,
                                         const char *wine_prefix,
                                         const char *request_json) {
    if (!executable_path || !*executable_path || !wine_prefix || !request_json) return EINVAL;
    @autoreleasepool {
        NSData *jsonData = [[NSString stringWithUTF8String:request_json] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *request = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
        if (![request isKindOfClass:[NSDictionary class]] || ![request[@"version"] isEqual:@1]) return EINVAL;
        if (ideck_runtime_prepare(wine_prefix) != 0) return ENOSYS;
        // Wine's upstream entry point currently accepts only a path.
        // Reject arguments instead of silently dropping them.
        NSArray *arguments = request[@"arguments"];
        if (![arguments isKindOfClass:[NSArray class]] || arguments.count != 0) return ENOTSUP;
        return ideck_wineprocess_start(executable_path);
    }
}
// The public ideck_madeira_launch_v1 ABI must only be exposed by a
// fully integrated Madeira runtime. Do not export it from this adapter:
// its presence participates in strict runtime readiness verification.
