#import <Foundation/Foundation.h>
#import <WebKit/WKWebView.h>

NS_ASSUME_NONNULL_BEGIN

@interface WIKNativeInspectorProbeRecord : NSObject

@property (nonatomic, readonly, copy) NSString *status;
@property (nonatomic, readonly, copy) NSString *stage;
@property (nonatomic, readonly, copy) NSString *message;
@property (nonatomic, readonly, copy, nullable) NSString *URLString;
@property (nonatomic, readonly, copy, nullable) NSString *requestIdentifier;
@property (nonatomic, readonly, copy, nullable) NSString *bodyPreview;
@property (nonatomic, readonly) BOOL base64Encoded;
@property (nonatomic, readonly, copy, nullable) NSString *rawBackendError;
@property (nonatomic, readonly, copy, nullable) NSString *rawMessage;

- (instancetype)initWithStatus:(NSString *)status
                         stage:(NSString *)stage
                       message:(NSString *)message
                     URLString:(nullable NSString *)URLString
             requestIdentifier:(nullable NSString *)requestIdentifier
                   bodyPreview:(nullable NSString *)bodyPreview
                 base64Encoded:(BOOL)base64Encoded
               rawBackendError:(nullable NSString *)rawBackendError
                    rawMessage:(nullable NSString *)rawMessage NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

typedef void (^WIKNativeInspectorProbeEventHandler)(WIKNativeInspectorProbeRecord *record);

@interface WIKNativeInspectorProbeSession : NSObject

- (instancetype)initWithWebView:(WKWebView *)webView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (void)startForURL:(NSURL *)url eventHandler:(WIKNativeInspectorProbeEventHandler)eventHandler;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
