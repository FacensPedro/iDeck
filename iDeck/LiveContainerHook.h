#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LiveContainerHook : NSObject

+ (void)installHooks;

/// Loads the main executable of the guest `.app` bundle at `appPath` into this process and
/// starts it. Returns NO and fills `errorMessage` when the guest cannot be loaded.
///
/// How it works (LiveContainer-style): the thin arm64 slice of the executable is copied and its
/// Mach-O file type is changed to MH_BUNDLE so dyld accepts it in dlopen(); `UIApplicationMain`
/// is rebound inside the guest so it runs on top of the host's UIApplication; `main` is then
/// called on the main thread. The copy must pass the device's code-signature validation
/// (patching the header invalidates the original signature, so the app has to be re-signed
/// or run on a device where signature checks are relaxed); otherwise dlopen() fails and the
/// dyld message is returned in `errorMessage`.
+ (BOOL)launchGuestAppAtPath:(NSString *)appPath errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

@end

NS_ASSUME_NONNULL_END
