#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WITransportRemoteInspectorBackendMessageHandler)(NSString *message);
typedef void (^WITransportRemoteInspectorFatalFailureHandler)(NSString *message);

#if TARGET_OS_OSX
@interface WITransportRemoteInspectorHost : NSObject

@property (nonatomic, copy, nullable) WITransportRemoteInspectorBackendMessageHandler backendMessageHandler;
@property (nonatomic, copy, nullable) WITransportRemoteInspectorFatalFailureHandler fatalFailureHandler;
@property (nonatomic, readonly, getter=isWindowVisible) BOOL windowVisible;
@property (nonatomic, readonly, getter=isWindowKey) BOOL windowKey;
@property (nonatomic, readonly, getter=isWindowMain) BOOL windowMain;

+ (nullable NSString *)availabilityFailureReason;

- (instancetype)initWithWebView:(WKWebView *)webView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)attach:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendMessageToFrontend:(NSString *)message error:(NSError * _Nullable * _Nullable)error;
- (void)performVisibilityMaintenance;
- (void)detach;

@end
#endif

NS_ASSUME_NONNULL_END
