// Objective-C interface over the C++ benchmark recorder, imported by Swift
// through the bridging header. No C++ types appear here.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IDBenchmarkRecorder : NSObject
/// Starts a session ("game" or "install"). NO when one is already running.
+ (BOOL)startWithKind:(NSString *)kind label:(NSString *)label;
/// Records the first time `event` happens in this session.
+ (void)mark:(NSString *)event;
+ (void)setInstallBytes:(uint64_t)bytes;
+ (BOOL)isRunning;
/// Stops the session and returns its measurements, or nil if none ran.
+ (nullable NSDictionary<NSString *, id> *)stop;
@end

NS_ASSUME_NONNULL_END
