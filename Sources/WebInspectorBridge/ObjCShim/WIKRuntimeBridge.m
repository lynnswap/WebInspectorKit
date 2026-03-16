#import "WIKRuntimeBridge.h"

#if TARGET_OS_OSX
#import <objc/runtime.h>
#endif

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
