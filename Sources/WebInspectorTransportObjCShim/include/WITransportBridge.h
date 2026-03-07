#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WITransportRootMessageHandler)(NSString *message);
typedef void (^WITransportPageMessageHandler)(NSString *message, NSString *targetIdentifier);
typedef void (^WITransportFatalFailureHandler)(NSString *message);

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

#if TARGET_OS_OSX
#ifdef __cplusplus
extern "C" {
#endif
FOUNDATION_EXPORT NSString * _Nullable WITransportRemoteInspectorHostAvailabilityFailureReason(void);
FOUNDATION_EXPORT NSObject * _Nullable WITransportCreateRemoteInspectorHost(WKWebView *webView);
FOUNDATION_EXPORT void WITransportRemoteInspectorHostSetBackendMessageHandler(NSObject *host, WITransportRootMessageHandler _Nullable handler);
FOUNDATION_EXPORT void WITransportRemoteInspectorHostSetFatalFailureHandler(NSObject *host, WITransportFatalFailureHandler _Nullable handler);
FOUNDATION_EXPORT BOOL WITransportRemoteInspectorHostAttach(NSObject *host, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL WITransportRemoteInspectorHostSendMessageToFrontend(NSObject *host, NSString *message, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void WITransportRemoteInspectorHostPerformVisibilityMaintenance(NSObject *host);
FOUNDATION_EXPORT BOOL WITransportRemoteInspectorHostIsWindowVisible(NSObject *host);
FOUNDATION_EXPORT BOOL WITransportRemoteInspectorHostIsWindowKey(NSObject *host);
FOUNDATION_EXPORT BOOL WITransportRemoteInspectorHostIsWindowMain(NSObject *host);
FOUNDATION_EXPORT void WITransportRemoteInspectorHostDetach(NSObject *host);
#ifdef __cplusplus
}
#endif
#endif

NS_ASSUME_NONNULL_END
