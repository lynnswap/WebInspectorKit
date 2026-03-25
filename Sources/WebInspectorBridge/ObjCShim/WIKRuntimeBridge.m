#import "WIKRuntimeBridge.h"

#if TARGET_OS_OSX
#import <objc/runtime.h>
#endif

typedef const struct OpaqueWKFrameHandle *WKFrameHandleRef;
typedef const struct OpaqueWKPage *WKPageRef;

NSErrorDomain const WIKRuntimeBridgeErrorDomain = @"WebInspectorBridge.WIKRuntimeBridge";

@implementation WIKRuntimeBridge

+ (NSObject *)objectResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return nil;
    }

    typedef id (*Getter)(id, SEL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL) {
        return nil;
    }

    Getter function = (Getter)implementation;
    id result = function(target, selector);
    return [result isKindOfClass:[NSObject class]] ? result : nil;
}

+ (NSNumber *)boolResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return nil;
    }

    typedef BOOL (*Getter)(id, SEL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL) {
        return nil;
    }

    Getter function = (Getter)implementation;
    return @(function(target, selector));
}

+ (BOOL)invokeVoidOnTarget:(NSObject *)target selectorName:(NSString *)selectorName {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return NO;
    }

    typedef void (*Invoker)(id, SEL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL) {
        return NO;
    }

    Invoker function = (Invoker)implementation;
    function(target, selector);
    return YES;
}

+ (BOOL)invokeActionStateOnTarget:(NSObject *)target
                    selectorName:(NSString *)selectorName
                   stateRawValue:(NSInteger)stateRawValue
                 notifyObservers:(BOOL)notifyObservers {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return NO;
    }

    typedef void (*Setter)(id, SEL, NSInteger, BOOL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL) {
        return NO;
    }

    Setter function = (Setter)implementation;
    function(target, selector, stateRawValue, notifyObservers);
    return YES;
}

+ (NSNumber *)frameIDForHandle:(id)handle {
    if (![handle isKindOfClass:[NSObject class]]) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"frameID");
    if (![handle respondsToSelector:selector]) {
        return nil;
    }

    typedef unsigned long long (*Getter)(id, SEL);
    IMP implementation = [handle methodForSelector:selector];
    if (implementation == NULL) {
        return nil;
    }

    Getter function = (Getter)implementation;
    return @(function(handle, selector));
}

+ (NSNumber *)frameIDForFrameInfo:(WKFrameInfo *)frameInfo {
    if (![frameInfo isKindOfClass:[WKFrameInfo class]]) {
        return nil;
    }

    id handle = [self objectResultFromTarget:frameInfo selectorName:@"_handle"];
    return [self frameIDForHandle:handle];
}

+ (WKPageRef)pageRefForWebView:(WKWebView *)webView {
    SEL selector = NSSelectorFromString(@"_pageForTesting");
    if (![webView respondsToSelector:selector]) {
        return NULL;
    }

    IMP implementation = [webView methodForSelector:selector];
    if (implementation == NULL) {
        return NULL;
    }

    typedef WKPageRef (*Getter)(id, SEL);
    Getter function = (Getter)implementation;
    return function(webView, selector);
}

+ (WKFrameHandleRef)frameHandleRefForFrameInfo:(WKFrameInfo *)frameInfo {
    id handle = [self objectResultFromTarget:frameInfo selectorName:@"_handle"];
    if (![handle isKindOfClass:[NSObject class]]) {
        return NULL;
    }
    // The frame-lookup C API unwraps the Objective-C WKObject wrapper and calls
    // -_apiObject internally. Passing the raw
    // _apiObject pointer here crashes because it is no longer an Objective-C object.
    return (WKFrameHandleRef)(__bridge void *)handle;
}

+ (NSValue *)pageRefValueForWebView:(WKWebView *)webView {
    WKPageRef pageRef = [self pageRefForWebView:webView];
    if (!pageRef) {
        return nil;
    }
    return [NSValue valueWithPointer:(void *)pageRef];
}

+ (NSValue *)frameHandleValueForFrameInfo:(WKFrameInfo *)frameInfo {
    WKFrameHandleRef frameHandleRef = [self frameHandleRefForFrameInfo:frameInfo];
    if (!frameHandleRef) {
        return nil;
    }
    return [NSValue valueWithPointer:(void *)frameHandleRef];
}

+ (void)appendFrameInfoIfNeeded:(WKFrameInfo *)frameInfo
                     frameInfos:(NSMutableArray<WKFrameInfo *> *)frameInfos
                   seenFrameIDs:(NSMutableSet<NSNumber *> *)seenFrameIDs {
    NSNumber *frameID = [self frameIDForFrameInfo:frameInfo];
    if (!frameID || [seenFrameIDs containsObject:frameID]) {
        return;
    }

    [seenFrameIDs addObject:frameID];
    [frameInfos addObject:frameInfo];
}

+ (void)appendFrameInfosFromTreeNode:(id)node
                          frameInfos:(NSMutableArray<WKFrameInfo *> *)frameInfos
                        seenFrameIDs:(NSMutableSet<NSNumber *> *)seenFrameIDs {
    if (![node isKindOfClass:[NSObject class]]) {
        return;
    }

    id frameInfo = [self objectResultFromTarget:node selectorName:@"info"];
    if ([frameInfo isKindOfClass:[WKFrameInfo class]]) {
        [self appendFrameInfoIfNeeded:frameInfo frameInfos:frameInfos seenFrameIDs:seenFrameIDs];
    }

    id childFrames = [self objectResultFromTarget:node selectorName:@"childFrames"];
    if (![childFrames isKindOfClass:[NSArray class]]) {
        return;
    }

    for (id childNode in (NSArray *)childFrames) {
        [self appendFrameInfosFromTreeNode:childNode frameInfos:frameInfos seenFrameIDs:seenFrameIDs];
    }
}

+ (NSArray<WKFrameInfo *> *)orderedFrameInfos:(NSArray<WKFrameInfo *> *)frameInfos {
    NSMutableArray<WKFrameInfo *> *orderedFrameInfos = [NSMutableArray arrayWithCapacity:frameInfos.count];
    for (WKFrameInfo *frameInfo in frameInfos) {
        if (frameInfo.isMainFrame)
            [orderedFrameInfos addObject:frameInfo];
    }
    for (WKFrameInfo *frameInfo in frameInfos) {
        if (!frameInfo.isMainFrame)
            [orderedFrameInfos addObject:frameInfo];
    }
    return [orderedFrameInfos copy];
}

+ (void)resolveMainFrameInfoForWebView:(WKWebView *)webView
                     completionHandler:(void (^)(NSArray<WKFrameInfo *> * _Nullable frameInfos))completionHandler {
    id mainFrameHandle = [self objectResultFromTarget:webView selectorName:@"_mainFrame"];
    if (!mainFrameHandle) {
        completionHandler(nil);
        return;
    }

    SEL selector = NSSelectorFromString(@"_frameInfoFromHandle:completionHandler:");
    if (![webView respondsToSelector:selector]) {
        completionHandler(nil);
        return;
    }

    IMP implementation = [webView methodForSelector:selector];
    if (implementation == NULL) {
        completionHandler(nil);
        return;
    }

    typedef void (*Invoker)(id, SEL, id, id);
    Invoker function = (Invoker)implementation;
    function(webView, selector, mainFrameHandle, [^(id frameInfo) {
        if ([frameInfo isKindOfClass:[WKFrameInfo class]]) {
            completionHandler([self orderedFrameInfos:@[frameInfo]]);
            return;
        }
        completionHandler(nil);
    } copy]);
}

+ (void)resolveFrameInfosFromFrameTreesForWebView:(WKWebView *)webView
                                completionHandler:(void (^)(NSArray<WKFrameInfo *> * _Nullable frameInfos))completionHandler {
    SEL selector = NSSelectorFromString(@"_frameTrees:");
    if (![webView respondsToSelector:selector]) {
        [self resolveMainFrameInfoForWebView:webView completionHandler:completionHandler];
        return;
    }

    IMP implementation = [webView methodForSelector:selector];
    if (implementation == NULL) {
        [self resolveMainFrameInfoForWebView:webView completionHandler:completionHandler];
        return;
    }

    typedef void (*Invoker)(id, SEL, id);
    Invoker function = (Invoker)implementation;
    function(webView, selector, [^(id frameTrees) {
        NSMutableArray<WKFrameInfo *> *frameInfos = [NSMutableArray array];
        NSMutableSet<NSNumber *> *seenFrameIDs = [NSMutableSet set];
        if ([frameTrees isKindOfClass:[NSSet class]]) {
            for (id rootNode in [(NSSet *)frameTrees allObjects]) {
                [self appendFrameInfosFromTreeNode:rootNode frameInfos:frameInfos seenFrameIDs:seenFrameIDs];
            }
        }

        if (frameInfos.count) {
            completionHandler([self orderedFrameInfos:frameInfos]);
            return;
        }

        [self resolveMainFrameInfoForWebView:webView completionHandler:completionHandler];
    } copy]);
}

+ (void)frameInfosForWebView:(WKWebView *)webView
           completionHandler:(void (^)(NSArray<WKFrameInfo *> * _Nullable frameInfos))completionHandler {
    if (!webView || !completionHandler) {
        if (completionHandler) {
            completionHandler(nil);
        }
        return;
    }

    SEL framesSelector = NSSelectorFromString(@"_frames:");
    if ([webView respondsToSelector:framesSelector]) {
        IMP implementation = [webView methodForSelector:framesSelector];
        if (implementation != NULL) {
            typedef void (*FramesInvoker)(id, SEL, id);
            FramesInvoker function = (FramesInvoker)implementation;
            function(webView, framesSelector, [^(id mainFrameNode) {
                NSMutableArray<WKFrameInfo *> *frameInfos = [NSMutableArray array];
                NSMutableSet<NSNumber *> *seenFrameIDs = [NSMutableSet set];
                [self appendFrameInfosFromTreeNode:mainFrameNode
                                        frameInfos:frameInfos
                                      seenFrameIDs:seenFrameIDs];
                if (frameInfos.count) {
                    completionHandler([self orderedFrameInfos:frameInfos]);
                    return;
                }
                [self resolveFrameInfosFromFrameTreesForWebView:webView completionHandler:completionHandler];
            } copy]);
            return;
        }
    }

    [self resolveFrameInfosFromFrameTreesForWebView:webView completionHandler:completionHandler];
}

+ (BOOL)invokeSetResourceLoadDelegateOnWebView:(WKWebView *)webView
                                  selectorName:(NSString *)selectorName
                                      delegate:(id)delegate {
    SEL selector = NSSelectorFromString(selectorName);
    if (![webView respondsToSelector:selector] && ![WKWebView instancesRespondToSelector:selector]) {
        return NO;
    }

    typedef void (*Setter)(id, SEL, id);
    IMP implementation = [webView methodForSelector:selector];
    if (implementation == NULL) {
        return NO;
    }

    Setter function = (Setter)implementation;
    function(webView, selector, delegate);
    return YES;
}

+ (WKContentWorld *)makeContentWorldWithConfigurationClassName:(NSString *)configurationClassName
                                             worldSelectorName:(NSString *)worldSelectorName
                                                       setters:(NSDictionary<NSString *, NSNumber *> *)setters {
    Class configurationClass = NSClassFromString(configurationClassName);
    if (configurationClass == Nil) {
        return nil;
    }

    id configuration = [[configurationClass alloc] init];
    if (configuration == nil) {
        return nil;
    }

    BOOL didApplySetter = NO;
    for (NSString *setterName in setters) {
        SEL setterSelector = NSSelectorFromString(setterName);
        if (![configuration respondsToSelector:setterSelector]) {
            continue;
        }

        IMP setterImplementation = [configuration methodForSelector:setterSelector];
        if (setterImplementation == NULL) {
            continue;
        }

        typedef void (*Setter)(id, SEL, BOOL);
        Setter setter = (Setter)setterImplementation;
        setter(configuration, setterSelector, setters[setterName].boolValue);
        didApplySetter = YES;
    }

    if (!didApplySetter) {
        return nil;
    }

    SEL worldSelector = NSSelectorFromString(worldSelectorName);
    Class worldClass = [WKContentWorld class];
    if (![worldClass respondsToSelector:worldSelector]) {
        return nil;
    }

    IMP worldImplementation = [worldClass methodForSelector:worldSelector];
    if (worldImplementation == NULL) {
        return nil;
    }

    typedef id (*WorldFactory)(id, SEL, id);
    WorldFactory factory = (WorldFactory)worldImplementation;
    id world = factory(worldClass, worldSelector, configuration);
    return [world isKindOfClass:[WKContentWorld class]] ? world : nil;
}

+ (id)makeJSBufferWithData:(NSData *)data
                 classNames:(NSArray<NSString *> *)classNames
          allocSelectorName:(NSString *)allocSelectorName
           initSelectorName:(NSString *)initSelectorName {
    SEL allocSelector = NSSelectorFromString(allocSelectorName);
    SEL initSelector = NSSelectorFromString(initSelectorName);

    for (NSString *className in classNames) {
        Class bufferClass = NSClassFromString(className);
        if (bufferClass == Nil) {
            continue;
        }

        if (![bufferClass instancesRespondToSelector:initSelector]) {
            continue;
        }

        if (![bufferClass respondsToSelector:allocSelector]) {
            continue;
        }

        IMP allocImplementation = [bufferClass methodForSelector:allocSelector];
        if (allocImplementation == NULL) {
            continue;
        }

        typedef id (*Allocator)(id, SEL);
        Allocator allocator = (Allocator)allocImplementation;
        id allocated = allocator(bufferClass, allocSelector);
        if (allocated == nil) {
            continue;
        }

        IMP initImplementation = [allocated methodForSelector:initSelector];
        if (initImplementation == NULL) {
            continue;
        }

        typedef id (*Initializer)(id, SEL, NSData *);
        Initializer initializer = (Initializer)initImplementation;
        id initialized = initializer(allocated, initSelector, data);
        if (initialized != nil) {
            return initialized;
        }
    }

    return nil;
}

+ (BOOL)addBufferOnController:(WKUserContentController *)controller
                 selectorName:(NSString *)selectorName
                       buffer:(id)buffer
                         name:(NSString *)name
                 contentWorld:(WKContentWorld *)contentWorld
              isPublicSignature:(BOOL)isPublicSignature {
    SEL selector = NSSelectorFromString(selectorName);
    if (![controller respondsToSelector:selector]) {
        return NO;
    }

    IMP implementation = [controller methodForSelector:selector];
    if (implementation == NULL) {
        return NO;
    }

    if (isPublicSignature) {
        typedef void (*PublicAdder)(id, SEL, id, NSString *, WKContentWorld *);
        PublicAdder adder = (PublicAdder)implementation;
        adder(controller, selector, buffer, name, contentWorld);
        return YES;
    }

    typedef void (*PrivateAdder)(id, SEL, id, WKContentWorld *, NSString *);
    PrivateAdder adder = (PrivateAdder)implementation;
    adder(controller, selector, buffer, contentWorld, name);
    return YES;
}

+ (BOOL)removeBufferOnController:(WKUserContentController *)controller
                    selectorName:(NSString *)selectorName
                            name:(NSString *)name
                    contentWorld:(WKContentWorld *)contentWorld {
    SEL selector = NSSelectorFromString(selectorName);
    if (![controller respondsToSelector:selector]) {
        return NO;
    }

    IMP implementation = [controller methodForSelector:selector];
    if (implementation == NULL) {
        return NO;
    }

    typedef void (*Remover)(id, SEL, NSString *, WKContentWorld *);
    Remover remover = (Remover)implementation;
    remover(controller, selector, name, contentWorld);
    return YES;
}

#if TARGET_OS_OSX
+ (NSWindow *)windowForView:(NSView *)view {
    return view.window;
}

+ (NSView *)menuToolbarControlFromItem:(NSMenuToolbarItem *)item {
    if (item.view != nil) {
        return item.view;
    }

    Ivar controlIvar = class_getInstanceVariable(NSMenuToolbarItem.class, "_control");
    if (controlIvar == NULL) {
        return nil;
    }

    id controlObject = object_getIvar(item, controlIvar);
    if ([controlObject isKindOfClass:NSView.class]) {
        return (NSView *)controlObject;
    }
    return nil;
}
#endif

@end
