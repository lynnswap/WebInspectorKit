#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const WIKRuntimeBridgeErrorDomain;

typedef NS_ERROR_ENUM(WIKRuntimeBridgeErrorDomain, WIKRuntimeBridgeErrorCode) {
    WIKRuntimeBridgeErrorCodeInvalidArgument = 1,
    WIKRuntimeBridgeErrorCodePageUnavailable = 2,
    WIKRuntimeBridgeErrorCodeFrameHandleUnavailable = 3,
    WIKRuntimeBridgeErrorCodeFrameUnavailable = 4,
    WIKRuntimeBridgeErrorCodeURLCreationFailed = 5,
    WIKRuntimeBridgeErrorCodeSymbolUnavailable = 6,
};

@interface WIKRuntimeBridge : NSObject

+ (nullable NSObject *)objectResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName;
+ (nullable NSNumber *)boolResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName;
+ (BOOL)invokeVoidOnTarget:(NSObject *)target selectorName:(NSString *)selectorName;
+ (BOOL)invokeActionStateOnTarget:(NSObject *)target
                    selectorName:(NSString *)selectorName
                   stateRawValue:(NSInteger)stateRawValue
                 notifyObservers:(BOOL)notifyObservers;
+ (void)frameInfosForWebView:(WKWebView *)webView
           completionHandler:(void (^)(NSArray<WKFrameInfo *> * _Nullable frameInfos))completionHandler;
+ (nullable NSNumber *)frameIDForFrameInfo:(WKFrameInfo *)frameInfo;
+ (nullable NSValue *)pageRefValueForWebView:(WKWebView *)webView;
+ (nullable NSValue *)frameHandleValueForFrameInfo:(WKFrameInfo *)frameInfo;
+ (BOOL)invokeSetResourceLoadDelegateOnWebView:(WKWebView *)webView
                                  selectorName:(NSString *)selectorName
                                      delegate:(nullable id)delegate;
+ (void)evaluateJavaScriptOnWebView:(WKWebView *)webView
                         javaScript:(NSString *)javaScript
                            inFrame:(nullable WKFrameInfo *)frame
                     inContentWorld:(WKContentWorld *)contentWorld
                  completionHandler:(void (^ _Nullable)(id _Nullable result, NSError * _Nullable error))completionHandler;

+ (nullable WKContentWorld *)makeContentWorldWithConfigurationClassName:(NSString *)configurationClassName
                                                       worldSelectorName:(NSString *)worldSelectorName
                                                                 setters:(NSDictionary<NSString *, NSNumber *> *)setters;

+ (nullable id)makeJSBufferWithData:(NSData *)data
                         classNames:(NSArray<NSString *> *)classNames
                  allocSelectorName:(NSString *)allocSelectorName
                   initSelectorName:(NSString *)initSelectorName;

+ (BOOL)addBufferOnController:(WKUserContentController *)controller
                 selectorName:(NSString *)selectorName
                       buffer:(id)buffer
                         name:(NSString *)name
                 contentWorld:(WKContentWorld *)contentWorld
              isPublicSignature:(BOOL)isPublicSignature;

+ (BOOL)removeBufferOnController:(WKUserContentController *)controller
                    selectorName:(NSString *)selectorName
                            name:(NSString *)name
                    contentWorld:(WKContentWorld *)contentWorld;

#if TARGET_OS_IPHONE
+ (nullable NSObject *)inspectorForWebView:(WKWebView *)webView;
+ (nullable NSNumber *)inspectorElementSelectionActiveForWebView:(WKWebView *)webView;
+ (BOOL)canEnableInspectorNodeSearchForWebView:(WKWebView *)webView;
+ (BOOL)enableInspectorNodeSearchForWebView:(WKWebView *)webView;
+ (BOOL)disableInspectorNodeSearchForWebView:(WKWebView *)webView;
+ (BOOL)hasInspectorNodeSearchRecognizerForWebView:(WKWebView *)webView;
+ (BOOL)removeInspectorNodeSearchRecognizersFromWebView:(WKWebView *)webView;
#endif

#if TARGET_OS_OSX
+ (nullable NSWindow *)windowForView:(NSView *)view;
+ (nullable NSView *)menuToolbarControlFromItem:(NSMenuToolbarItem *)item;
#endif

@end

NS_ASSUME_NONNULL_END
