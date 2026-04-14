#import "WKWebView+CallAsyncJavaScriptCompat.h"

@implementation WKWebView (WIKCallAsyncJavaScriptCompat)

- (void)wki_callAsyncJavaScript:(NSString *)functionBody
                      arguments:(NSDictionary<NSString *, id> *)arguments
                        inFrame:(WKFrameInfo *)frame
                 inContentWorld:(WKContentWorld *)contentWorld
              completionHandler:(void (^)(id, NSError *))completionHandler
{
    [self callAsyncJavaScript:functionBody arguments:arguments inFrame:frame inContentWorld:contentWorld completionHandler:completionHandler];
}

@end
