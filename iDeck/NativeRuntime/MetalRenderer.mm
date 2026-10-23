#import "MadeiraRuntimeBridge.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <new>
struct IDeckMetalRenderer {
    id<MTLDevice> device;
    id<MTLTexture> texture;
};
extern "C" bool ideck_metal_available(void) {
    return MTLCreateSystemDefaultDevice() != nil;
}
extern "C" void *ideck_metal_renderer_create(int32_t width, int32_t height) {
    if (width < 1 || height < 1 || width > 8192 || height > 8192) return nullptr;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return nullptr;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)width height:(NSUInteger)height mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        descriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (!texture) return nullptr;
        auto *renderer = new (std::nothrow) IDeckMetalRenderer{device, texture};
        return renderer;
    }
}
extern "C" void *ideck_metal_renderer_texture(void *renderer) {
    if (!renderer) return nullptr;
    return (__bridge void *)static_cast<IDeckMetalRenderer *>(renderer)->texture;
}
extern "C" void ideck_metal_renderer_destroy(void *renderer) {
    delete static_cast<IDeckMetalRenderer *>(renderer);
}
