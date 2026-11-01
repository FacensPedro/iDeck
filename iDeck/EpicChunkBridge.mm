#import "EpicChunkBridge.h"
#include "EpicChunkCodec.hpp"

@implementation IDEpicChunkCodec

+ (nullable NSData *)inflate:(NSData *)data size:(NSUInteger)size {
    NSMutableData *output = [NSMutableData dataWithLength:size];
    if (output == nil) return nil;
    const auto status = ideck::epic::inflateWindow(static_cast<const uint8_t *>(data.bytes), data.length,
                                                   static_cast<uint8_t *>(output.mutableBytes), size);
    return status == ideck::epic::CodecStatus::ok ? output : nil;
}

+ (NSData *)sha1:(NSData *)data {
    uint8_t digest[20];
    ideck::epic::sha1(static_cast<const uint8_t *>(data.bytes), data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

@end
