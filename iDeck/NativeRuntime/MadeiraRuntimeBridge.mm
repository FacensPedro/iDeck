#import "MadeiraRuntimeBridge.h"
#import "../NativeRuntimeDiagnostics.h"
#import <Foundation/Foundation.h>
#include <cerrno>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>

extern "C" int32_t ideck_runtime_prepare(const char *wine_prefix) {
    if (wine_prefix == nullptr || wine_prefix[0] == '\0') return EINVAL;
    struct stat info {};
    if (stat(wine_prefix, &info) != 0 || !S_ISDIR(info.st_mode)) return ENOENT;
    if (!ideck_metal_available() || !ideck_fex_available() ||
        !ideck_wineserver_available() || !ideck_wineprocess_available() ||
        !ideck_dxmt_available() || !ideck_d3d12_available()) return ENOSYS;
    if (!ideck_fex_initialize()) return EAGAIN;
    if (!ideck_wineserver_initialize(wine_prefix)) return EAGAIN;
    return 0;
}

extern "C" int32_t ideck_runtime_launch(const char *executable_path,
                                         const char *wine_prefix,
                                         const char *request_json) {
    if (!executable_path || !*executable_path || !wine_prefix || !*wine_prefix ||
        !request_json || !*request_json) return EINVAL;
    @autoreleasepool {
        NSData *json = [[NSString stringWithUTF8String:request_json] dataUsingEncoding:NSUTF8StringEncoding];
        if (json == nil || json.length > 16384) return EINVAL;
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if (![request isKindOfClass:[NSDictionary class]] ||
            ![request[@"version"] isEqual:@1]) return EINVAL;
        NSArray *arguments = request[@"arguments"];
        if (![arguments isKindOfClass:[NSArray class]] || arguments.count > 64) return EINVAL;
        if ([request[@"is32Bit"] boolValue]) return ENOTSUP;

        NSString *prefix = [[NSString stringWithUTF8String:wine_prefix] stringByStandardizingPath];
        NSString *executable = [[NSString stringWithUTF8String:executable_path] stringByStandardizingPath];
        NSString *drive = [prefix stringByAppendingPathComponent:@"drive_c"];
        NSString *canonicalDrive = [[NSURL fileURLWithPath:drive] URLByResolvingSymlinksInPath].path;
        NSString *canonicalExecutable = [[NSURL fileURLWithPath:executable] URLByResolvingSymlinksInPath].path;
        NSString *root = [canonicalDrive stringByAppendingString:@"/"];
        if (![canonicalExecutable hasPrefix:root] ||
            ![[canonicalExecutable.pathExtension lowercaseString] isEqualToString:@"exe"] ||
            !ideck_native_validate_pe(canonicalExecutable.fileSystemRepresentation)) return EACCES;

        NSString *relative = [canonicalExecutable substringFromIndex:root.length];
        if (relative.length == 0 || relative.length >= 480) return ENAMETOOLONG;
        NSString *winExe = [@"C:\\" stringByAppendingString:
                            [relative stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
        NSMutableArray<NSString *> *quoted = [NSMutableArray arrayWithCapacity:arguments.count];
        for (id arg in arguments) {
            if (![arg isKindOfClass:[NSString class]] ||
                [arg length] >= 1024 || [arg rangeOfString:@"\""].location != NSNotFound ||
                [arg rangeOfString:@"\n"].location != NSNotFound ||
                [arg rangeOfString:@"\r"].location != NSNotFound) return EINVAL;
            NSString *value = (NSString *)arg;
            if ([value rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound ||
                value.length == 0) value = [NSString stringWithFormat:@"\"%@\"", value];
            [quoted addObject:value];
        }
        NSString *argString = [quoted componentsJoinedByString:@" "];
        if (argString.length >= 4096) return E2BIG;

        int32_t prepared = ideck_runtime_prepare(wine_prefix);
        if (prepared != 0) return prepared;
        if (setenv("WINEPREFIX", wine_prefix, 1) != 0 ||
            setenv("MADEIRA_EXE", winExe.UTF8String, 1) != 0 ||
            setenv("MADEIRA_ARGS", argString.UTF8String, 1) != 0) return errno;
        return ideck_wineprocess_start(wine_prefix);
    }
}

// Export the public launch ABI only for a build explicitly linked against
// Madeira's full FEX/Wine/DXMT implementations and verified guest DLL farm.
// Never turn this on for an interface-only IPA.
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
extern "C" int32_t ideck_madeira_launch_v1(const char *executable_path,
                                            const char *wine_prefix,
                                            const char *request_json) {
    return ideck_runtime_launch(executable_path, wine_prefix, request_json);
}
#endif
