#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WebInspectorNativeMessageHandler)(NSString *message);
typedef void (^WebInspectorNativeFatalFailureHandler)(NSString *message);

typedef struct {
    uint64_t connectFrontendAddress;
    uint64_t disconnectFrontendAddress;
    uint64_t stringFromUTF8Address;
    uint64_t stringImplToNSStringAddress;
    uint64_t destroyStringImplAddress;
    uint64_t backendDispatcherDispatchAddress;
} WebInspectorNativeResolvedSymbols;

typedef struct {
    BOOL found;
    BOOL usedFallbackRange;
    NSInteger resolvedOffset;
    NSUInteger attemptedOffsetCount;
    NSUInteger validCandidateCount;
    NSUInteger scannedByteCount;
} WebInspectorNativeControllerDiscoveryTestResult;

@interface WebInspectorNativeBridge : NSObject

@property (nonatomic, copy, nullable) WebInspectorNativeMessageHandler messageHandler;
@property (nonatomic, copy, nullable) WebInspectorNativeFatalFailureHandler fatalFailureHandler;

- (instancetype)initWithWebView:(WKWebView *)webView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)attachWithResolvedSymbols:(WebInspectorNativeResolvedSymbols)resolvedSymbols
                             error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendJSONString:(NSString *)message error:(NSError * _Nullable * _Nullable)error;
- (void)detach;

@end

FOUNDATION_EXPORT WebInspectorNativeControllerDiscoveryTestResult WebInspectorNativeFindInspectorControllerForTesting(
    const void *pageProxy,
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset
);

FOUNDATION_EXPORT WebInspectorNativeControllerDiscoveryTestResult WebInspectorNativeRunControllerDiscoveryScenarioForTesting(
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset,
    NSInteger primaryControllerOffset,
    NSInteger secondaryControllerOffset
);

NS_ASSUME_NONNULL_END
