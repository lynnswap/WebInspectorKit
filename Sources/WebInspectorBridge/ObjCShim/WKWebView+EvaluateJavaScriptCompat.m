#import "WKWebView+EvaluateJavaScriptCompat.h"

@implementation WKWebView (WIKEvaluateJavaScriptCompat)

- (void)wi_evaluateJavaScript:(NSString *)javaScript
                       inFrame:(WKFrameInfo *)frame
                inContentWorld:(WKContentWorld *)contentWorld
             completionHandler:(void (^)(id, NSError *))completionHandler
{
    [self evaluateJavaScript:javaScript inFrame:frame inContentWorld:contentWorld completionHandler:completionHandler];
}

@end
