#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and, if it raises an Objective-C exception, returns the
/// exception's description instead of letting it end the process. Returns
/// nil when the block completes.
///
/// Swift cannot catch NSException: one thrown through a Swift frame calls
/// std::terminate and the app is gone, with no crash report worth reading.
/// AVAudioEngine raises them for conditions it considers programmer error,
/// and some of those it can be talked into by a Bluetooth headset changing
/// its mind about its format mid-call. This is the one place in the app
/// that can turn such an exception into an error.
FOUNDATION_EXPORT NSString * _Nullable CLIOCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
