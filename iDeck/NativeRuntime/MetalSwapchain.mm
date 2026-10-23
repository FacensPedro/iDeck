#import "RuntimeSupport.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
struct IDeckMetalSwapchain { CAMetalLayer *layer; };
extern "C" void *ideck_metal_swapchain_create(void *metal_layer) {
    if (!metal_layer) return nullptr;
    id object = (__bridge id)metal_layer;
    if (![object isKindOfClass:[CAMetalLayer class]]) return nullptr;
    CAMetalLayer *layer = (CAMetalLayer *)object;
    if (!layer.device) layer.device = MTLCreateSystemDefaultDevice();
    if (!layer.device) return nullptr;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;
    return new IDeckMetalSwapchain{layer};
}
extern "C" void ideck_metal_swapchain_destroy(void *swapchain) {
    delete static_cast<IDeckMetalSwapchain *>(swapchain);
}
