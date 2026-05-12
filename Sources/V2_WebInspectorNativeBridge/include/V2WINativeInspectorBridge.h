#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^V2WINativeMessageHandler)(NSString *message);
typedef void (^V2WINativeFatalFailureHandler)(NSString *message);

typedef struct {
    uint64_t connectFrontendAddress;
    uint64_t disconnectFrontendAddress;
    uint64_t stringFromUTF8Address;
    uint64_t stringImplToNSStringAddress;
    uint64_t destroyStringImplAddress;
    uint64_t backendDispatcherDispatchAddress;
} V2WINativeResolvedSymbols;

typedef struct {
    BOOL found;
    BOOL usedFallbackRange;
    NSInteger resolvedOffset;
    NSUInteger attemptedOffsetCount;
    NSUInteger validCandidateCount;
    NSUInteger scannedByteCount;
} V2WINativeControllerDiscoveryTestResult;

@interface V2WINativeInspectorBridge : NSObject

@property (nonatomic, copy, nullable) V2WINativeMessageHandler messageHandler;
@property (nonatomic, copy, nullable) V2WINativeFatalFailureHandler fatalFailureHandler;

- (instancetype)initWithWebView:(WKWebView *)webView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)attachWithResolvedSymbols:(V2WINativeResolvedSymbols)resolvedSymbols
                             error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendJSONString:(NSString *)message error:(NSError * _Nullable * _Nullable)error;
- (void)detach;

@end

FOUNDATION_EXPORT V2WINativeControllerDiscoveryTestResult V2WINativeFindInspectorControllerForTesting(
    const void *pageProxy,
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset
);

FOUNDATION_EXPORT V2WINativeControllerDiscoveryTestResult V2WINativeRunControllerDiscoveryScenarioForTesting(
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset,
    NSInteger primaryControllerOffset,
    NSInteger secondaryControllerOffset
);

NS_ASSUME_NONNULL_END
