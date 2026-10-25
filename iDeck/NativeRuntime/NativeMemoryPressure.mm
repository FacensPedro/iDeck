#import "NativeMemoryManager.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

extern "C" void ideck_native_memory_install_notifications(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                           object:nil
                            queue:nil
                       usingBlock:^(__unused NSNotification *notification) {
            ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_CRITICAL);
        }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                           object:nil
                            queue:nil
                       usingBlock:^(__unused NSNotification *notification) {
            ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_WARNING);
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                           object:nil
                            queue:nil
                       usingBlock:^(__unused NSNotification *notification) {
            ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_NORMAL);
        }];
    });
}
