#import "RuntimeSupport.h"
#import <GameController/GameController.h>
#import <Foundation/Foundation.h>
static BOOL controller_observing = NO;
extern "C" void ideck_controller_start(void) {
    @synchronized ([GCController class]) {
        if (controller_observing) return;
        controller_observing = YES;
        [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    }
}
extern "C" void ideck_controller_stop(void) {
    @synchronized ([GCController class]) {
        if (!controller_observing) return;
        controller_observing = NO;
        [GCController stopWirelessControllerDiscovery];
    }
}
