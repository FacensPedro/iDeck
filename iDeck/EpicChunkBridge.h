// Objective-C interface over the C++ Epic chunk codec, imported by Swift
// through the bridging header. No C++ types appear here.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IDEpicChunkCodec : NSObject
/// The decompressed window, or nil when the zlib stream is invalid or does
/// not end at exactly `size` bytes.
+ (nullable NSData *)inflate:(NSData *)data size:(NSUInteger)size;
/// 20-byte SHA-1 digest.
+ (NSData *)sha1:(NSData *)data;
@end

NS_ASSUME_NONNULL_END
