#import "LiveContainerHook.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <limits.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach-o/nlist.h>
#import <libkern/OSByteOrder.h>

static NSBundle *gGuestBundle = nil;
static id gGuestDelegate = nil;
static id gGuestSceneDelegate = nil;
static UIWindow *gGuestWindow = nil;

@interface NSBundle (LiveContainer)
- (NSString *)lc_bundlePath;
+ (NSBundle *)lc_mainBundle;
@end

@implementation NSBundle (LiveContainer)

/// Reports the guest path as the main bundle's path while a guest is selected.
- (NSString *)lc_bundlePath {
    const char *guestAppPath = getenv("GUEST_APP_PATH");
    if (guestAppPath != NULL && [self isEqual:[NSBundle mainBundle]]) {
        return [NSString stringWithUTF8String:guestAppPath];
    }
    return [self lc_bundlePath]; // implementations are exchanged: this calls the original
}

/// After a guest has been started, the guest bundle is reported as the main bundle.
+ (NSBundle *)lc_mainBundle {
    if (gGuestBundle) return gGuestBundle;
    return [self lc_mainBundle]; // implementations are exchanged: this calls the original
}

@end

@implementation LiveContainerHook

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod([NSBundle class], @selector(bundlePath));
        Method replacement = class_getInstanceMethod([NSBundle class], @selector(lc_bundlePath));
        if (original && replacement) method_exchangeImplementations(original, replacement);

        Method originalMain = class_getClassMethod([NSBundle class], @selector(mainBundle));
        Method replacementMain = class_getClassMethod([NSBundle class], @selector(lc_mainBundle));
        if (originalMain && replacementMain) method_exchangeImplementations(originalMain, replacementMain);
    });
}

#pragma mark - Guest loading

static BOOL LCFail(NSString **out, NSString *message) {
    if (out) *out = message;
    return NO;
}

static void LCPatchExecutablePath(char *path, size_t capacity) {
    const char *oldPrefix = "@executable_path";
    const char *newPrefix = "@loader_path";
    size_t oldPrefixLength = strlen(oldPrefix);
    size_t newPrefixLength = strlen(newPrefix);
    size_t pathLength = strnlen(path, capacity);
    if (pathLength >= capacity || strncmp(path, oldPrefix, oldPrefixLength) != 0) return;
    size_t suffixLength = pathLength - oldPrefixLength;
    size_t newLength = newPrefixLength + suffixLength;
    if (newLength + 1 > capacity) return;
    memmove(path + newPrefixLength, path + oldPrefixLength, suffixLength + 1);
    memcpy(path, newPrefix, newPrefixLength);
    memset(path + newLength + 1, 0, capacity - newLength - 1);
}

static void LCPatchExecutablePathsInLoadCommands(struct mach_header_64 *mh) {
    struct load_command *lc = (struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmdsize < sizeof(struct load_command)) return;
        if (lc->cmd == LC_RPATH) {
            struct rpath_command *rpath = (struct rpath_command *)lc;
            if (rpath->path.offset < lc->cmdsize) {
                char *path = (char *)rpath + rpath->path.offset;
                LCPatchExecutablePath(path, lc->cmdsize - rpath->path.offset);
            }
        } else if (lc->cmd == LC_LOAD_DYLIB ||
                   lc->cmd == LC_LOAD_WEAK_DYLIB ||
                   lc->cmd == LC_REEXPORT_DYLIB ||
                   lc->cmd == LC_LOAD_UPWARD_DYLIB ||
                   lc->cmd == LC_LAZY_LOAD_DYLIB) {
            struct dylib_command *dylib = (struct dylib_command *)lc;
            if (dylib->dylib.name.offset < lc->cmdsize) {
                char *path = (char *)dylib + dylib->dylib.name.offset;
                LCPatchExecutablePath(path, lc->cmdsize - dylib->dylib.name.offset);
            }
        }
        lc = (struct load_command *)((uint8_t *)lc + lc->cmdsize);
    }
}

/// Copies the arm64 slice of the guest executable and turns it into an MH_BUNDLE.
static NSString *LCPreparePatchedBinary(NSString *appPath, NSDictionary *info, NSString **error) {
    NSString *execName = info[@"CFBundleExecutable"];
    if (![execName isKindOfClass:[NSString class]] || execName.length == 0 || [execName containsString:@"/"]) {
        if (error) *error = @"Invalid CFBundleExecutable in guest Info.plist";
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:[appPath stringByAppendingPathComponent:execName]];
    if (data.length < sizeof(struct mach_header_64)) {
        if (error) *error = @"Guest executable missing or too small";
        return nil;
    }

    uint8_t *bytes = data.mutableBytes;
    size_t sliceOffset = 0, sliceLength = data.length;
    uint32_t magic = *(uint32_t *)bytes;
    if (magic == FAT_CIGAM) {
        struct fat_header *fh = (struct fat_header *)bytes;
        uint32_t count = OSSwapBigToHostInt32(fh->nfat_arch);
        if (sizeof(*fh) + (size_t)count * sizeof(struct fat_arch) > data.length) {
            if (error) *error = @"Corrupt fat header";
            return nil;
        }
        struct fat_arch *archs = (struct fat_arch *)(fh + 1);
        BOOL found = NO;
        for (uint32_t i = 0; i < count; i++) {
            if ((cpu_type_t)OSSwapBigToHostInt32(archs[i].cputype) == CPU_TYPE_ARM64) {
                sliceOffset = OSSwapBigToHostInt32(archs[i].offset);
                sliceLength = OSSwapBigToHostInt32(archs[i].size);
                found = YES;
                break;
            }
        }
        if (!found || sliceOffset > data.length || sliceLength > data.length - sliceOffset) {
            if (error) *error = @"Guest executable has no arm64 slice";
            return nil;
        }
    }

    struct mach_header_64 *mh = (struct mach_header_64 *)(bytes + sliceOffset);
    if (sliceLength < sizeof(*mh) || mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) {
        if (error) *error = @"Guest executable is not a 64-bit arm64 Mach-O";
        return nil;
    }
    if (mh->filetype != MH_EXECUTE && mh->filetype != MH_BUNDLE) {
        if (error) *error = @"Guest executable has an unexpected Mach-O type";
        return nil;
    }
    LCPatchExecutablePathsInLoadCommands(mh);
    mh->filetype = MH_BUNDLE;

    NSString *out = [appPath stringByAppendingPathComponent:[execName stringByAppendingString:@".iDeck.bundle"]];
    NSData *slice = [NSData dataWithBytes:bytes + sliceOffset length:sliceLength];
    if (![slice writeToFile:out options:NSDataWritingAtomic error:nil]) {
        if (error) *error = @"Could not write the patched guest binary";
        return nil;
    }
    return out;
}

static const struct mach_header_64 *LCFindImage(NSString *path, intptr_t *slide) {
    char want[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, want)) return NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char have[PATH_MAX];
        if (name && realpath(name, have) && strcmp(have, want) == 0) {
            if (slide) *slide = _dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

static uintptr_t LCFindEntryPoint(const struct mach_header_64 *mh) {
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_MAIN) {
            const struct entry_point_command *ep = (const struct entry_point_command *)lc;
            return (uintptr_t)mh + (uintptr_t)ep->entryoff;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    return 0;
}

/// Minimal fishhook-style rebinding of one imported symbol inside a single image.
/// Only plain (non-PAC) pointer sections are handled, which covers arm64 apps.
static BOOL LCRebindSymbol(const struct mach_header_64 *mh, intptr_t slide, const char *symbol, void *replacement) {
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;

    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!symtab || !dysymtab || !linkedit) return NO;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *nl = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strtab = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    BOOL rebound = NO;
    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__DATA", 6) == 0) {
                const struct section_64 *sect = (const struct section_64 *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
                    uint32_t type = sect->flags & SECTION_TYPE;
                    if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
                    void **slots = (void **)((uintptr_t)slide + sect->addr);
                    const uint32_t *indices = indirect + sect->reserved1;
                    for (uint64_t k = 0; k < sect->size / sizeof(void *); k++) {
                        uint32_t idx = indices[k];
                        if (idx == INDIRECT_SYMBOL_ABS || idx == INDIRECT_SYMBOL_LOCAL) continue;
                        if (strcmp(strtab + nl[idx].n_un.n_strx, symbol) != 0) continue;
                        vm_address_t page = (vm_address_t)((uintptr_t)&slots[k] & ~(uintptr_t)(vm_page_size - 1));
                        if (vm_protect(mach_task_self(), page, vm_page_size, FALSE,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) continue;
                        slots[k] = replacement;
                        rebound = YES;
                    }
                }
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    return rebound;
}

static UIWindowScene *LCHostScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

/// Replacement for UIApplicationMain inside the guest: the host already owns the UIApplication,
/// so instead of starting a run loop we drive the guest's launch sequence manually.
static int LCGuestUIApplicationMain(int argc, char *_Nullable *_Nonnull argv, NSString *principalClassName, NSString *delegateClassName) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindowScene *hostScene = LCHostScene();
    NSDictionary *info = gGuestBundle.infoDictionary;

    Class delegateClass = delegateClassName ? NSClassFromString(delegateClassName) : Nil;
    if (delegateClass) {
        gGuestDelegate = [[delegateClass alloc] init];
        if ([gGuestDelegate respondsToSelector:@selector(application:didFinishLaunchingWithOptions:)]) {
            [gGuestDelegate application:app didFinishLaunchingWithOptions:@{}];
        }
    }

    UIWindow *window = nil;
    if ([gGuestDelegate respondsToSelector:@selector(window)]) window = [gGuestDelegate window];

    // Scene-based guests create their window in the scene delegate.
    if (!window.rootViewController && hostScene) {
        NSDictionary *manifest = info[@"UIApplicationSceneManifest"];
        NSArray *configs = manifest[@"UISceneConfigurations"][@"UIWindowSceneSessionRoleApplication"];
        NSString *sceneClassName = [configs.firstObject isKindOfClass:[NSDictionary class]] ? configs.firstObject[@"UISceneDelegateClassName"] : nil;
        Class sceneClass = sceneClassName ? NSClassFromString(sceneClassName) : Nil;
        if (sceneClass) {
            gGuestSceneDelegate = [[sceneClass alloc] init];
            if ([gGuestSceneDelegate respondsToSelector:@selector(scene:willConnectToSession:options:)]) {
                [gGuestSceneDelegate scene:hostScene willConnectToSession:hostScene.session options:nil];
            }
            if ([gGuestSceneDelegate respondsToSelector:@selector(window)]) window = [gGuestSceneDelegate window];
        }
    }

    // Storyboard-based guests: UIKit would normally build the window.
    if (!window.rootViewController) {
        NSString *storyboard = info[@"UIMainStoryboardFile"];
        if (storyboard.length) {
            UIViewController *vc = [[UIStoryboard storyboardWithName:storyboard bundle:gGuestBundle] instantiateInitialViewController];
            if (vc) {
                window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
                window.rootViewController = vc;
            }
        }
    }

    if (window.rootViewController) {
        if (hostScene) window.windowScene = hostScene;
        window.windowLevel = UIWindowLevelNormal + 1;
        window.hidden = NO;
        [window makeKeyAndVisible];
        gGuestWindow = window;
    } else {
        NSLog(@"[LiveContainer] guest did not provide a window");
    }
    return 0;
}

+ (BOOL)launchGuestAppAtPath:(NSString *)appPath errorMessage:(NSString **)errorMessage {
    if (![NSThread isMainThread]) return LCFail(errorMessage, @"Guests must be launched from the main thread");
    if (gGuestBundle) return LCFail(errorMessage, @"A guest app is already running; restart iDeck to launch another");
    BOOL isDir = NO;
    if (![appPath.pathExtension isEqualToString:@"app"] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:appPath isDirectory:&isDir] || !isDir) {
        return LCFail(errorMessage, @"Not a valid .app bundle");
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
    if (!info) return LCFail(errorMessage, @"Guest Info.plist could not be read");

    NSString *prepError = nil;
    NSString *patched = LCPreparePatchedBinary(appPath, info, &prepError);
    if (!patched) return LCFail(errorMessage, prepError);

    dlerror();
    void *handle = dlopen(patched.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    if (!handle) {
        const char *dlerr = dlerror();
        return LCFail(errorMessage, [NSString stringWithFormat:@"dlopen failed: %s", dlerr ? dlerr : "unknown error"]);
    }

    intptr_t slide = 0;
    const struct mach_header_64 *mh = LCFindImage(patched, &slide);
    uintptr_t entry = mh ? LCFindEntryPoint(mh) : 0;
    if (!entry) {
        dlclose(handle);
        return LCFail(errorMessage, @"Could not locate the guest entry point (LC_MAIN)");
    }

    setenv("GUEST_APP_PATH", appPath.fileSystemRepresentation, 1);
    gGuestBundle = [NSBundle bundleWithPath:appPath];
    LCRebindSymbol(mh, slide, "_UIApplicationMain", (void *)LCGuestUIApplicationMain);

    NSString *execPath = [appPath stringByAppendingPathComponent:info[@"CFBundleExecutable"]];
    char *argv0 = strdup(execPath.fileSystemRepresentation);
    dispatch_async(dispatch_get_main_queue(), ^{
        char *argv[2] = { argv0, NULL };
        ((int (*)(int, char **))entry)(1, argv);
    });
    return YES;
}

@end
