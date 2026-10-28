#import "MadeiraRuntimeBridge.h"
#import "../NativeRuntimeDiagnostics.h"
#import <Foundation/Foundation.h>
#include <cerrno>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <mutex>
#include <cstdio>

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
    // FEX may already have initialized its own pool even if StikDebug later
    // detached; a new Wine pool still requires the live BRK handler. Report
    // a permissions/debugger error instead of incorrectly calling this OOM.
    if (!ideck_wine_jit_pool_ready() && !ideck_jit_debugger_attached()) return EPERM;
    // Upstream Madeira requires RX/RW pool environment exports before __wine_main.
    // Without these the first ARM64EC dispatcher faults on a non-executable PE page.
    if (!ideck_wine_jit_pool_prepare() || !ideck_wine_jit_pool_ready()) return ENOMEM;
    if (!ideck_wineserver_initialize(wine_prefix)) return EAGAIN;
    return 0;
}

static int32_t ideck_invalid_launch(const char *reason) {
    fprintf(stderr, "[iDeck native launch] EINVAL: %s\n", reason);
    return EINVAL;
}

// Re-quote parsed Windows parameters for Madeira's single command-line string.
// Backslashes immediately before quotes (and at the end of quoted parameters)
// require doubling according to Windows CRT command-line parsing rules.
static NSString *ideck_quote_windows_argument(NSString *arg) {
    BOOL requiresQuotes = arg.length == 0 ||
        [arg rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound ||
        [arg rangeOfString:@"\""].location != NSNotFound;
    if (!requiresQuotes) return arg;
    NSMutableString *result = [NSMutableString stringWithString:@"\""];
    NSUInteger backslashes = 0;
    for (NSUInteger index = 0; index < arg.length; index++) {
        unichar ch = [arg characterAtIndex:index];
        if (ch == '\\') {
            backslashes++;
            continue;
        }
        if (ch == '"') {
            [result appendString:[@"" stringByPaddingToLength:backslashes * 2 + 1
                                                   withString:@"\\"
                                              startingAtIndex:0]];
            [result appendString:@"\""];
        } else {
            [result appendString:[@"" stringByPaddingToLength:backslashes
                                                   withString:@"\\"
                                              startingAtIndex:0]];
            [result appendFormat:@"%C", ch];
        }
        backslashes = 0;
    }
    [result appendString:[@"" stringByPaddingToLength:backslashes * 2
                                           withString:@"\\"
                                      startingAtIndex:0]];
    [result appendString:@"\""];
    return result;
}

static std::mutex ideck_launch_mutex;
static bool ideck_wine_session_started = false;

extern "C" int32_t ideck_runtime_launch(const char *executable_path,
                                         const char *wine_prefix,
                                         const char *request_json) {
    std::unique_lock<std::mutex> launch_lock(ideck_launch_mutex, std::try_to_lock);
    if (!launch_lock.owns_lock()) return EBUSY;
    if (ideck_wineprocess_running()) return EALREADY;
    if (ideck_wine_session_started) return EALREADY;
    if (!executable_path || !*executable_path || !wine_prefix || !*wine_prefix ||
        !request_json || !*request_json) return ideck_invalid_launch("empty executable, prefix or launch request");
    @autoreleasepool {
        NSData *json = [[NSString stringWithUTF8String:request_json] dataUsingEncoding:NSUTF8StringEncoding];
        if (json == nil || json.length > 16384) return ideck_invalid_launch("invalid or oversized launch JSON");
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if (![request isKindOfClass:[NSDictionary class]] ||
            ![request[@"version"] isEqual:@1]) return ideck_invalid_launch("missing or unsupported launch request version");
        NSArray *arguments = request[@"arguments"];
        if (![arguments isKindOfClass:[NSArray class]] || arguments.count > 64) return ideck_invalid_launch("invalid arguments array or too many arguments");
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
                [arg rangeOfString:@"\n"].location != NSNotFound ||
                [arg rangeOfString:@"\r"].location != NSNotFound)
                return ideck_invalid_launch("malformed argument or control character");
            [quoted addObject:ideck_quote_windows_argument((NSString *)arg)];
        }
        NSString *argString = [quoted componentsJoinedByString:@" "];
        if (argString.length >= 4096) return E2BIG;

        /* Direct Steam game launches must carry their own app identity. Without
         * it upstream Madeira currently falls back to a fixed test-game ID. */
        id steamID = request[@"steamAppID"];
        id steamFolder = request[@"steamInstallDirectory"];
        id requestedWorkdir = request[@"steamWorkingDirectory"];
        if ((steamID == nil) != (steamFolder == nil)) return ideck_invalid_launch("steamAppID and steamInstallDirectory must be provided together");
        if (requestedWorkdir != nil && steamID == nil)
            return ideck_invalid_launch("Steam working folder requires an app identity");
        if ([request[@"isSteam"] boolValue] && steamID == nil) {
            if (setenv("MADEIRA_DOCK_SESSION", "1", 1)) return errno;
        } else {
            unsetenv("MADEIRA_DOCK_SESSION");
        }
        unsetenv("MADEIRA_STEAM_APPID");
        unsetenv("MADEIRA_STEAM_APPPATH");
        unsetenv("MADEIRA_WORKDIR");
        if (steamID != nil) {
            if (![steamID isKindOfClass:[NSNumber class]] ||
                ![steamFolder isKindOfClass:[NSString class]]) return ideck_invalid_launch("invalid Steam app identity types");
            NSNumber *appID = (NSNumber *)steamID;
            NSString *appIDText = appID.stringValue;
            if (appID.unsignedIntValue == 0 || appIDText.length > 10 ||
                [appIDText rangeOfCharacterFromSet:
                    [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)
                return ideck_invalid_launch("invalid Steam app ID");
            NSString *canonicalFolder = [[NSURL fileURLWithPath:(NSString *)steamFolder]
                URLByResolvingSymlinksInPath].path;
            if (![canonicalFolder hasPrefix:root] ||
                ![[NSFileManager defaultManager] fileExistsAtPath:canonicalFolder]) return EACCES;
            NSString *relativeFolder = [canonicalFolder substringFromIndex:root.length];
            if (relativeFolder.length == 0 || relativeFolder.length >= 850) return ENAMETOOLONG;
            NSString *windowsFolder = [@"C:\\" stringByAppendingString:
                [relativeFolder stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
            NSString *workingDirectory = canonicalExecutable.stringByDeletingLastPathComponent;
            if (requestedWorkdir != nil) {
                if (![requestedWorkdir isKindOfClass:[NSString class]] ||
                    [(NSString *)requestedWorkdir length] >= 1024)
                    return ideck_invalid_launch("invalid Steam working directory");
                workingDirectory = [[NSURL fileURLWithPath:(NSString *)requestedWorkdir]
                    URLByResolvingSymlinksInPath].path;
            }
            BOOL insideFolder = [workingDirectory isEqualToString:canonicalFolder] ||
                [workingDirectory hasPrefix:[canonicalFolder stringByAppendingString:@"/"]];
            BOOL insideDrive = [workingDirectory hasPrefix:root];
            BOOL directoryExists = NO;
            if (!insideFolder || !insideDrive ||
                ![[NSFileManager defaultManager] fileExistsAtPath:workingDirectory
                                                      isDirectory:&directoryExists] ||
                !directoryExists)
                return ideck_invalid_launch("Steam working directory is missing or outside installed game");
            NSString *relativeWorkingDirectory = [workingDirectory substringFromIndex:root.length];
            NSString *windowsWorkingDirectory = [@"C:\\" stringByAppendingString:
                [relativeWorkingDirectory stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
            if (windowsWorkingDirectory.length >= 480) return ENAMETOOLONG;
            /* SteamAppPath is the install root, but Wine's working directory
             * is the launch option's own workingdir (or EXE's parent). Games
             * with a Binaries/Win64 EXE need these paths to differ. */
            if (setenv("MADEIRA_STEAM_APPID", appIDText.UTF8String, 1) ||
                setenv("MADEIRA_STEAM_APPPATH", windowsFolder.UTF8String, 1) ||
                setenv("MADEIRA_WORKDIR", windowsWorkingDirectory.UTF8String, 1)) return errno;
            fprintf(stderr, "[iDeck game launch] Steam app=%s exe=%s cwd=%s\n",
                    appIDText.UTF8String, winExe.UTF8String, windowsWorkingDirectory.UTF8String);
        }
        int32_t prepared = ideck_runtime_prepare(wine_prefix);
        if (prepared != 0) return prepared;
        if (setenv("MADEIRA_ENV_LOCKED", "MADEIRA_EXE,MADEIRA_ARGS,MADEIRA_STEAM_APPID,MADEIRA_STEAM_APPPATH,MADEIRA_WORKDIR", 1))
            return errno;
        if (setenv("WINEPREFIX", wine_prefix, 1) != 0 ||
            setenv("MADEIRA_EXE", winExe.UTF8String, 1) != 0 ||
            setenv("MADEIRA_ARGS", argString.UTF8String, 1) != 0) return errno;
        int32_t result = ideck_wineprocess_start(wine_prefix);
        if (result == 0) ideck_wine_session_started = true;
        return result;
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
