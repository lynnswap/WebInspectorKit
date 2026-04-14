#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WKWebView (WIKCallAsyncJavaScriptCompat)

- (void)wi_callAsyncJavaScript:(NSString *)functionBody
                      arguments:(nullable NSDictionary<NSString *, id> *)arguments
                        inFrame:(nullable WKFrameInfo *)frame
                 inContentWorld:(WKContentWorld *)contentWorld
              completionHandler:(void (^ _Nullable)(id _Nullable result, NSError * _Nullable error))completionHandler;

@end

NS_ASSUME_NONNULL_END
