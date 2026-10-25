#import "NativePerformance.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static CAMetalLayer *ideck_checked_layer(void *pointer) {
    if (!pointer) return nil;
    id object = (__bridge id)pointer;
    if (![object isKindOfClass:[CAMetalLayer class]]) return nil;
    return (CAMetalLayer *)object;
}

extern "C" bool ideck_metal_frame_prepare(void *metal_layer) {
    CAMetalLayer *layer = ideck_checked_layer(metal_layer);
    if (!layer) return false;
    if (!layer.device) layer.device = MTLCreateSystemDefaultDevice();
    if (!layer.device) return false;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;
    layer.allowsNextDrawableTimeout = YES;
    return true;
}

extern "C" bool ideck_metal_frame_resize(void *metal_layer, uint32_t pixel_width, uint32_t pixel_height) {
    if (!pixel_width || !pixel_height || pixel_width > 8192 || pixel_height > 8192) return false;
    CAMetalLayer *layer = ideck_checked_layer(metal_layer);
    if (!layer || !ideck_metal_frame_prepare(metal_layer)) return false;
    CGSize new_size = CGSizeMake((CGFloat)pixel_width, (CGFloat)pixel_height);
    if (!CGSizeEqualToSize(layer.drawableSize, new_size)) {
        layer.drawableSize = new_size;
    }
    return true;
}
