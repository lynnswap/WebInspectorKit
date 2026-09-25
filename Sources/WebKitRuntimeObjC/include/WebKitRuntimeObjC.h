#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A retained snapshot of WebKit's native page storage. Use only on the main thread.
/// The pointer is valid while this snapshot is retained; callers still own the native ABI contract.
@interface WKRuntimePageStorage : NSObject
@property (nonatomic, readonly) void *address;
@property (nonatomic, readonly) NSUInteger byteCount;
+ (nullable WKRuntimePageStorage *)storageForWebView:(WKWebView *)webView NS_SWIFT_NAME(storage(for:));
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
