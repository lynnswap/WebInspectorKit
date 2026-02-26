#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface WIKRuntimeBridge : NSObject

+ (nullable NSObject *)objectResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName;
+ (nullable NSNumber *)boolResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName;

+ (BOOL)invokeVoidOnTarget:(NSObject *)target selectorName:(NSString *)selectorName;
+ (BOOL)invokeActionStateOnTarget:(NSObject *)target
                    selectorName:(NSString *)selectorName
                   stateRawValue:(NSInteger)stateRawValue
                 notifyObservers:(BOOL)notifyObservers;
+ (BOOL)invokeSetResourceLoadDelegateOnWebView:(WKWebView *)webView
                                  selectorName:(NSString *)selectorName
                                      delegate:(nullable id)delegate;

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

#if TARGET_OS_OSX
+ (nullable NSWindow *)windowForView:(NSView *)view;
+ (nullable NSView *)menuToolbarControlFromItem:(NSMenuToolbarItem *)item;
#endif

@end

NS_ASSUME_NONNULL_END
