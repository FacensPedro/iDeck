#import "MadeiraRuntimeBridge.h"
#import "../NativeRuntimeDiagnostics.h"
#import <Foundation/Foundation.h>
#include <cerrno>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <mutex>

#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
extern "C" void madeira_seed_prefix_if_needed(const char *prefix_path);
#endif

static bool ideck_valid_wine_prefix(const char *path) {
    if (!path || !*path) return false;
    NSString *base = [NSString stringWithUTF8String:path];
    if (!base) return false;
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:[base stringByAppendingPathComponent:@".update-timestamp"]] &&
           [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"system.reg"]] &&
           [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"drive_c/windows"]];
}

extern "C" int32_t ideck_runtime_prepare(const char *wine_prefix) {
    if (wine_prefix == nullptr || wine_prefix[0] == '\0') return EINVAL;
    struct stat info {};
    if (stat(wine_prefix, &info) != 0 || !S_ISDIR(info.st_mode)) return ENOENT;
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    // Seed the registry and DOS links before starting wineserver.
    madeira_seed_prefix_if_needed(wine_prefix);
    if (!ideck_valid_wine_prefix(wine_prefix)) return ENOENT;
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    for (NSString *file in @[ @"arm64ec-windows/xtajit64.dll",
                              @"arm64ec-windows/ntdll.dll",
                              @"arm64ec-windows/winemetal.dll",
                              @"aarch64-windows/winemetal.dll" ]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[bundle stringByAppendingPathComponent:file]]) {
            return ENOENT;
        }
    }
#else
    return ENOSYS;
#endif
    if (!ideck_metal_available() || !ideck_fex_available() ||
        !ideck_wineserver_available() || !ideck_wineprocess_available() ||
        !ideck_dxmt_available() || !ideck_d3d12_available()) return ENOSYS;
    // CS_DEBUGGED alone can remain set after the JIT debugger detaches.
    // Never enter upstream BRK #0xf00d without a live debugger or FEX pool.
    if (!ideck_fex_jit_ready()) return EPERM;
    if (!ideck_fex_initialize()) return EAGAIN;
    if (!ideck_wineserver_initialize(wine_prefix)) return EAGAIN;
    return 0;
}

static std::mutex ideck_launch_mutex;

extern "C" int32_t ideck_runtime_launch(const char *executable_path,
                                         const char *wine_prefix,
                                         const char *request_json) {
    std::unique_lock<std::mutex> launch_lock(ideck_launch_mutex, std::try_to_lock);
    if (!launch_lock.owns_lock()) return EBUSY;
    if (ideck_wineprocess_running() || ideck_wineprocess_session_used()) return EALREADY;
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
        if ([request[@"is32Bit"] boolValue]) {
            // Upstream WineProcessBridge detects the target's PE32 machine
            // and starts its WoW64 path. Never attempt it with an empty i386
            // farm, or the guest can fail after reserving its address window.
            NSString *bundlePath = NSBundle.mainBundle.bundlePath;
            for (NSString *name in @[ @"i386-windows/ntdll.dll",
                                      @"i386-windows/kernel32.dll",
                                      @"aarch64-windows/xtajit.dll",
                                      @"aarch64-windows/wow64.dll",
                                      @"aarch64-windows/wow64win.dll" ]) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:
                      [bundlePath stringByAppendingPathComponent:name]]) return ENOTSUP;
            }
        }

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
            if (![arg isKindOfClass:[NSString class]] || [arg length] >= 1024 ||
                [arg rangeOfString:@"\""].location != NSNotFound ||
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
        /* Direct Steam game launches must carry their own app identity. Without
         * it upstream Madeira currently falls back to a fixed test-game ID. */
        id steamID = request[@"steamAppID"];
        id steamFolder = request[@"steamInstallDirectory"];
        if ((steamID == nil) != (steamFolder == nil)) return EINVAL;
        if ([request[@"isSteam"] boolValue]) {
            if (setenv("MADEIRA_DOCK_SESSION", "1", 1)) return errno;
        } else {
            unsetenv("MADEIRA_DOCK_SESSION");
        }
        unsetenv("MADEIRA_STEAM_APPID");
        unsetenv("MADEIRA_STEAM_APPPATH");
        if ([request[@"isSteam"] boolValue] && steamID != nil) return EINVAL;
        NSString *steamWorkingFolder = nil;
        if (steamID != nil) {
            if (![steamID isKindOfClass:[NSNumber class]] ||
                ![steamFolder isKindOfClass:[NSString class]]) return EINVAL;
            NSNumber *appID = (NSNumber *)steamID;
            NSString *appIDText = appID.stringValue;
            if (appID.unsignedIntValue == 0 || appIDText.length > 10 ||
                [appIDText rangeOfCharacterFromSet:
                    [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)
                return EINVAL;
            NSString *canonicalFolder = [[NSURL fileURLWithPath:(NSString *)steamFolder]
                URLByResolvingSymlinksInPath].path;
            if (![canonicalFolder hasPrefix:root] ||
                ![[NSFileManager defaultManager] fileExistsAtPath:canonicalFolder]) return EACCES;
            NSString *relativeFolder = [canonicalFolder substringFromIndex:root.length];
            if (relativeFolder.length == 0 || relativeFolder.length >= 850) return ENAMETOOLONG;
            NSString *windowsFolder = [@"C:\\" stringByAppendingString:
                [relativeFolder stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
            steamWorkingFolder = windowsFolder;
            if (setenv("MADEIRA_STEAM_APPID", appIDText.UTF8String, 1) ||
                setenv("MADEIRA_STEAM_APPPATH", windowsFolder.UTF8String, 1)) return errno;
        }
        NSString *launchExe = winExe;
        NSString *launchArgs = argString;
        NSString *workdir = steamWorkingFolder;
        if ([request[@"launchInDesktop"] boolValue]) {
            if ([winExe containsString:@"\""] ||
                [winExe containsString:@"\r"] || [winExe containsString:@"\n"]) return EINVAL;
            launchExe = @"explorer.exe";
            launchArgs = [NSString stringWithFormat:@"/desktop=shell,960x540 \"%@\"%@",
                          winExe, argString.length ? [@" " stringByAppendingString:argString] : @""];
            if (launchArgs.length >= 4096) return E2BIG;
            if (!workdir) {
                NSRange lastSlash = [winExe rangeOfString:@"\\" options:NSBackwardsSearch];
                workdir = lastSlash.location == NSNotFound
                    ? @"C:\\" : [winExe substringToIndex:lastSlash.location];
            }
            if (setenv("MADEIRA_DESKTOP", "1", 1)) return errno;
        } else {
            unsetenv("MADEIRA_DESKTOP");
        }
        if (workdir && workdir.length > 0 && setenv("MADEIRA_WORKDIR", workdir.UTF8String, 1))
            return errno;
        if (!workdir) unsetenv("MADEIRA_WORKDIR");
        if ([request[@"waitForChildProcesses"] boolValue]) {
            if (setenv("MADEIRA_WAIT_CHILDREN", "1", 1)) return errno;
        } else {
            unsetenv("MADEIRA_WAIT_CHILDREN");
        }
        if (setenv("MADEIRA_ENV_LOCKED",
                   "MADEIRA_EXE,MADEIRA_ARGS,MADEIRA_STEAM_APPID,MADEIRA_STEAM_APPPATH,MADEIRA_DESKTOP,MADEIRA_WORKDIR,MADEIRA_WAIT_CHILDREN", 1))
            return errno;
        if (setenv("WINEPREFIX", wine_prefix, 1) != 0 ||
            setenv("MADEIRA_EXE", launchExe.UTF8String, 1) != 0 ||
            setenv("MADEIRA_ARGS", launchArgs.UTF8String, 1) != 0) return errno;
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
