#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WITransportRootMessageHandler)(NSString *message, NSDictionary * _Nullable parsedMessage);
typedef void (^WITransportPageMessageHandler)(NSString *message, NSDictionary * _Nullable parsedMessage, NSString *targetIdentifier);
typedef void (^WITransportFatalFailureHandler)(NSString *message);

typedef struct {
    BOOL found;
    BOOL usedFallbackRange;
    NSInteger resolvedOffset;
    NSUInteger attemptedOffsetCount;
    NSUInteger validCandidateCount;
    NSUInteger scannedByteCount;
} WITransportControllerDiscoveryTestResult;

@interface WITransportBridge : NSObject

@property (nonatomic, copy, nullable) WITransportRootMessageHandler rootMessageHandler;
@property (nonatomic, copy, nullable) WITransportPageMessageHandler pageMessageHandler;
@property (nonatomic, copy, nullable) WITransportFatalFailureHandler fatalFailureHandler;

- (instancetype)initWithWebView:(WKWebView *)webView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)attachWithConnectFrontendAddress:(uint64_t)connectFrontendAddress
              disconnectFrontendAddress:(uint64_t)disconnectFrontendAddress
                                  error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendRootJSONString:(NSString *)message error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendPageJSONString:(NSString *)message
          targetIdentifier:(NSString *)targetIdentifier
           outerIdentifier:(NSNumber *)outerIdentifier
                     error:(NSError * _Nullable * _Nullable)error;
- (void)detach;

@end

FOUNDATION_EXPORT WITransportControllerDiscoveryTestResult WITransportFindInspectorControllerForTesting(
    const void *pageProxy,
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset
);

FOUNDATION_EXPORT WITransportControllerDiscoveryTestResult WITransportRunControllerDiscoveryScenarioForTesting(
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset,
    NSInteger primaryControllerOffset,
    NSInteger secondaryControllerOffset
);

NS_ASSUME_NONNULL_END
