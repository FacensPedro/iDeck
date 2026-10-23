#import "RuntimeSupport.h"
#import <Metal/Metal.h>
extern "C" bool ideck_metal_shader_library_available(void *metal_device) {
    if (!metal_device) return false;
    id<MTLDevice> device = (__bridge id<MTLDevice>)metal_device;
    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (library) return true;
    (void)error;
    return false;
}
