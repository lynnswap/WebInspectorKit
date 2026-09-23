#import "WebKitRuntimeObjC.h"
#import <objc/runtime.h>
#import <malloc/malloc.h>
#include <memory>

static SEL selector(const uint8_t *bytes, size_t count)
{
    std::unique_ptr<char[]> name(new char[count + 1]);
    for (size_t i = 0; i < count; ++i)
        name[i] = bytes[i] ^ 0xA7;
    name[count] = 0;
    return sel_registerName(name.get());
}

static void *pointerResult(id target, SEL selector)
{
    // WKObject inherits NSProxy, so NSObject reflection would invoke forwarding.
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!method)
        return nullptr;
    using Getter = void *(*)(id, SEL);
    return reinterpret_cast<Getter>(method_getImplementation(method))(target, selector);
}

@implementation WKRuntimePageStorage {
    id _owner;
    WKWebView *_webView;
}
+ (WKRuntimePageStorage *)storageForWebView:(WKWebView *)webView
{
    // _pageForTesting / _apiObject: ask WebKit for its wrapper and native object.
    // This avoids duplicating RefPtr storage or indexed-storage alignment.
    static const uint8_t pageName[] = { 0xF8, 0xD7, 0xC6, 0xC0, 0xC2, 0xE1, 0xC8, 0xD5, 0xF3, 0xC2, 0xD4, 0xD3, 0xCE, 0xC9, 0xC0 };
    static const uint8_t objectName[] = { 0xF8, 0xC6, 0xD7, 0xCE, 0xE8, 0xC5, 0xCD, 0xC2, 0xC4, 0xD3 };
    id owner = (__bridge id)pointerResult(webView, selector(pageName, sizeof(pageName)));
    void *page = pointerResult(owner, selector(objectName, sizeof(objectName)));
    if (!page)
        return nil;
    const auto base = reinterpret_cast<uintptr_t>((__bridge void *)owner);
    const auto address = reinterpret_cast<uintptr_t>(page);
    const size_t allocationSize = malloc_size((__bridge const void *)owner);
    if (address < base || address - base >= allocationSize)
        return nil;
    auto storage = [[self alloc] initPrivate];
    storage->_owner = owner;
    storage->_webView = webView;
    storage->_address = page;
    storage->_byteCount = allocationSize - (address - base);
    return storage;
}
- (instancetype)initPrivate { return [super init]; }
@end
