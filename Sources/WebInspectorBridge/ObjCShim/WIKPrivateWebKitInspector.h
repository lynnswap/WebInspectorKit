#import <TargetConditionals.h>
#import <WebKit/WebKit.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@class _WKInspector;

@interface WKWebView (WIKPrivateWebKitInspector)
@property (readonly, nonatomic) _WKInspector *_inspector;
@end

@interface _WKInspector : NSObject
@property (readonly, nonatomic) BOOL isElementSelectionActive;
- (void)connect;
@end

#if TARGET_OS_IPHONE
@interface UIView (WIKPrivateInspectorNodeSearch)
- (void)_enableInspectorNodeSearch;
- (void)_disableInspectorNodeSearch;
@end
#endif

NS_ASSUME_NONNULL_END
