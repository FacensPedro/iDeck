#import "VirtualControllerBridge.h"

static GCVirtualController *Try(NSSet<NSString *> *elements) {
    @try {
        GCVirtualControllerConfiguration *cfg = [GCVirtualControllerConfiguration new];
        cfg.elements = elements;
        return [[GCVirtualController alloc] initWithConfiguration:cfg];
    } @catch (NSException *e) {
        return nil;
    }
}

GCVirtualController *IDeckMakeVirtualController(NSSet<NSString *> *elements) {
    GCVirtualController *vc = Try(elements);
    if (vc) return vc;
    NSMutableSet<NSString *> *ok = [NSMutableSet set];
    for (NSString *element in elements) {
        if (Try([NSSet setWithObject:element])) [ok addObject:element];
    }
    return ok.count ? Try(ok) : nil;
}
