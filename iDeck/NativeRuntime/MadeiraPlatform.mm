// Madeira platform layer: Metal renderer/swapchain, DXMT availability,
// audio session, memory-pressure notifications and session lifecycle.
#include "MadeiraStaticABI.h"
#import "RuntimeSupport.h"
#import "NativePerformance.h"
#import "NativeMemoryManager.h"
#import "MadeiraRuntimeBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <atomic>
#include <new>

// MARK: - Metal device and renderer

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
        return new (std::nothrow) IDeckMetalRenderer{device, texture};
    }
}

extern "C" void *ideck_metal_renderer_texture(void *renderer) {
    if (!renderer) return nullptr;
    return (__bridge void *)static_cast<IDeckMetalRenderer *>(renderer)->texture;
}

extern "C" void ideck_metal_renderer_destroy(void *renderer) {
    delete static_cast<IDeckMetalRenderer *>(renderer);
}

extern "C" bool ideck_metal_shader_library_available(void *metal_device) {
    if (!metal_device) return false;
    id<MTLDevice> device = (__bridge id<MTLDevice>)metal_device;
    return [device newDefaultLibrary] != nil;
}

// MARK: - CAMetalLayer frames and swapchain

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

struct IDeckMetalSwapchain { CAMetalLayer *layer; };

extern "C" void *ideck_metal_swapchain_create(void *metal_layer) {
    CAMetalLayer *layer = ideck_checked_layer(metal_layer);
    if (!layer || !ideck_metal_frame_prepare(metal_layer)) return nullptr;
    auto *swapchain = new (std::nothrow) IDeckMetalSwapchain{layer};
    if (swapchain) ideck_performance_record_swapchain();
    return swapchain;
}

extern "C" void ideck_metal_swapchain_destroy(void *swapchain) {
    delete static_cast<IDeckMetalSwapchain *>(swapchain);
}

// MARK: - DXMT

extern "C" bool ideck_dxmt_available(void) {
    if (MTLCreateSystemDefaultDevice() == nil) return false;
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    // A missing DXMT renderer implementation must fail the native link.
    return &madeira_get_present_count != nullptr;
#else
    return false;
#endif
}

// MARK: - Audio

extern "C" bool ideck_audio_session_activate(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:&error]) return false;
    return [session setActive:YES error:&error];
}

// MARK: - Memory pressure

extern "C" void ideck_native_memory_install_notifications(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil
                        usingBlock:^(__unused NSNotification *notification) {
            ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_CRITICAL);
        }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                        usingBlock:^(__unused NSNotification *notification) {
            ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_WARNING);
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                        usingBlock:^(__unused NSNotification *notification) {
            ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_NORMAL);
        }];
    });
}

// MARK: - Session lifecycle

static std::atomic<int32_t> session_state{IDECK_SESSION_STOPPED};

extern "C" void ideck_session_stop(void) {
    ideck_controller_stop();
    ideck_native_memory_trim();
    session_state.store(IDECK_SESSION_STOPPED);
}

extern "C" int32_t ideck_session_state(void) { return session_state.load(); }
