#import <Foundation/Foundation.h>
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

NS_ASSUME_NONNULL_END
