#import "LiveContainerHook.h"
#import <objc/runtime.h>

@implementation LiveContainerHook

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self swizzleBundleMethods];
    });
}

+ (void)swizzleBundleMethods {
    Class class = [NSBundle class];
    
    SEL originalSelector = @selector(bundlePath);
    SEL swizzledSelector = @selector(lc_bundlePath);
    
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
    
    BOOL didAddMethod = class_addMethod(class,
                                        originalSelector,
                                        method_getImplementation(swizzledMethod),
                                        method_getTypeEncoding(swizzledMethod));
    
    if (didAddMethod) {
        class_replaceMethod(class,
                            swizzledSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

- (NSString *)lc_bundlePath {
    NSString *guestAppPath = [[[NSProcessInfo processInfo] environment] objectForKey:@"GUEST_APP_PATH"];
    if (guestAppPath && [self isEqual:[NSBundle mainBundle]]) {
        return guestAppPath;
    }
    return [self lc_bundlePath];
}

@end
