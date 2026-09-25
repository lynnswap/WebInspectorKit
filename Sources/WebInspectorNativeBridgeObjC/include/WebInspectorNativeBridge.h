#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <WebKit/WKWebView.h>
#include <ABIBridge/Inspection.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const WebInspectorNativeBridgeErrorDomain;

typedef NS_ERROR_ENUM(WebInspectorNativeBridgeErrorDomain, WebInspectorNativeBridgeError) {
    WebInspectorNativeBridgeErrorUnsupported = 1,
    WebInspectorNativeBridgeErrorAttachFailed = 2,
    WebInspectorNativeBridgeErrorEncodingFailed = 4,
    WebInspectorNativeBridgeErrorAttachmentInvalidated = 5,
};

typedef void (^WebInspectorNativeMessageHandler)(NSString *message);
typedef void (^WebInspectorNativeFatalFailureHandler)(NSString *message);
typedef void (^WebInspectorNativeWebContentProcessTerminationHandler)(void);

typedef struct {
    // Borrowed for the duration of attach or a test call. The implementation
    // retains symbols needed by the connection independently of this struct.
    ABIResolvedSymbol * _Nullable connectFrontend;
    ABIResolvedSymbol * _Nullable disconnectFrontend;
    ABIResolvedSymbol * _Nullable stringFromUTF8;
    ABIResolvedSymbol * _Nullable stringImplToNSString;
    ABIResolvedSymbol * _Nullable derefStringImpl;
    ABIResolvedSymbol * _Nullable dispatchMessageFromRemote;
    ABIResolvedSymbol * _Nullable debuggableVTable;
} WebInspectorNativeResolvedSymbols;

FOUNDATION_EXPORT NSString *WebInspectorNativeRoundTripStringForTesting(
    NSString *string, WebInspectorNativeResolvedSymbols symbols
);

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
