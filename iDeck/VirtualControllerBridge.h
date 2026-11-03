#import <GameController/GameController.h>

NS_ASSUME_NONNULL_BEGIN
/// Builds a GCVirtualController without letting an unsupported element
/// abort the app: elements the system rejects are dropped one by one.
GCVirtualController * _Nullable IDeckMakeVirtualController(NSSet<NSString *> *elements);
NS_ASSUME_NONNULL_END
