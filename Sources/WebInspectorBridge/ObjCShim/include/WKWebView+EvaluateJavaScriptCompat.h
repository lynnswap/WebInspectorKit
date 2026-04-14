#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WKWebView (WIKEvaluateJavaScriptCompat)

- (void)wi_evaluateJavaScript:(NSString *)javaScript
                       inFrame:(nullable WKFrameInfo *)frame
                inContentWorld:(WKContentWorld *)contentWorld
             completionHandler:(void (^ _Nullable)(id _Nullable result, NSError * _Nullable error))completionHandler;

@end

NS_ASSUME_NONNULL_END
