#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * _Nullable WebInspectorNativeDemangleCXXSymbol(const char *name);

typedef void (^WebInspectorNativeMessageHandler)(NSString *message);
typedef void (^WebInspectorNativeFatalFailureHandler)(NSString *message);
typedef void (^WebInspectorNativeWebContentProcessTerminationHandler)(void);

typedef struct {
    uint64_t connectFrontendAddress;
    uint64_t disconnectFrontendAddress;
    uint64_t stringFromUTF8Address;
    uint64_t stringImplToNSStringAddress;
    uint64_t derefStringImplAddress;
    uint64_t dispatchMessageFromRemoteAddress;
    uint64_t debuggableVTableAddress;
} WebInspectorNativeResolvedSymbols;

typedef struct {
    BOOL found;
    NSInteger offset;
    NSUInteger matches;
} WebInspectorNativeTargetDiscoveryTestResult;

@interface WebInspectorNativeBridge : NSObject

@property (nonatomic, copy, nullable) WebInspectorNativeMessageHandler messageHandler;
@property (nonatomic, copy, nullable) WebInspectorNativeFatalFailureHandler fatalFailureHandler;
@property (nonatomic, copy, nullable) WebInspectorNativeWebContentProcessTerminationHandler webContentProcessTerminationHandler;

- (instancetype)initWithWebView:(WKWebView *)webView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)attachWithResolvedSymbols:(WebInspectorNativeResolvedSymbols)resolvedSymbols
                             error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendJSONString:(NSString *)message error:(NSError * _Nullable * _Nullable)error;
- (void)detach;

@end

FOUNDATION_EXPORT WebInspectorNativeTargetDiscoveryTestResult WebInspectorNativeRunTargetDiscoveryForTesting(
    NSUInteger byteCount, NSInteger cachedOffset, NSInteger primaryOffset, NSInteger secondaryOffset, BOOL sameTarget
);

FOUNDATION_EXPORT void WebInspectorNativeDeliverFrontendMessageForTesting(
    WebInspectorNativeBridge *bridge,
    NSString *message
);

NS_ASSUME_NONNULL_END
