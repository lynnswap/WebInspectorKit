#import <Foundation/Foundation.h>
#import <WebKit/WKWebView.h>
#import <objc/message.h>
#import <dlfcn.h>

typedef const void *WKPageRef;
typedef const void *WKStringRef;
typedef const void *WKTypeRef;

typedef void (*WKPageDidReceiveMessageFromInjectedBundleCallback)(WKPageRef, WKStringRef, WKTypeRef, const void *);
typedef void (*WKPageDidReceiveSynchronousMessageFromInjectedBundleCallback)(WKPageRef, WKStringRef, WKTypeRef, WKTypeRef *, const void *);

typedef struct WKPageInjectedBundleClientBase {
    int version;
    const void *clientInfo;
} WKPageInjectedBundleClientBase;

typedef struct WKPageInjectedBundleClientV0 {
    WKPageInjectedBundleClientBase base;
    WKPageDidReceiveMessageFromInjectedBundleCallback didReceiveMessageFromInjectedBundle;
    WKPageDidReceiveSynchronousMessageFromInjectedBundleCallback didReceiveSynchronousMessageFromInjectedBundle;
} WKPageInjectedBundleClientV0;

typedef void (*WKPageSetPageInjectedBundleClientFunc)(WKPageRef, const WKPageInjectedBundleClientBase *);
typedef bool (*WKStringIsEqualToUTF8CStringFunc)(WKStringRef, const char *);
typedef size_t (*WKStringGetUTF8CStringFunc)(WKStringRef, char *, size_t);

static WKPageSetPageInjectedBundleClientFunc wkPageSetClient;
static WKStringIsEqualToUTF8CStringFunc wkStringIsEqual;
static WKStringGetUTF8CStringFunc wkStringGetUTF8;
static bool didResolveSymbols;
static bool didInstallClient;

static void resolveSymbols(void)
{
    if (didResolveSymbols)
        return;
    didResolveSymbols = true;
    wkPageSetClient = (WKPageSetPageInjectedBundleClientFunc)dlsym(RTLD_DEFAULT, "WKPageSetPageInjectedBundleClient");
    wkStringIsEqual = (WKStringIsEqualToUTF8CStringFunc)dlsym(RTLD_DEFAULT, "WKStringIsEqualToUTF8CString");
    wkStringGetUTF8 = (WKStringGetUTF8CStringFunc)dlsym(RTLD_DEFAULT, "WKStringGetUTF8CString");
}

static WKPageRef pageRefForWebView(WKWebView *webView)
{
    SEL selector = NSSelectorFromString(@"_pageForTesting");
    if ([webView respondsToSelector:selector])
        return ((WKPageRef (*)(id, SEL))objc_msgSend)(webView, selector);
    selector = NSSelectorFromString(@"_pageRef");
    if ([webView respondsToSelector:selector])
        return ((WKPageRef (*)(id, SEL))objc_msgSend)(webView, selector);
    return NULL;
}

static void didReceiveMessageFromInjectedBundle(WKPageRef page, WKStringRef messageName, WKTypeRef messageBody, const void *clientInfo)
{
    (void)page;
    (void)clientInfo;
    if (!wkStringIsEqual || !wkStringGetUTF8)
        return;
    if (!wkStringIsEqual(messageName, "MiniBrowserInjectedBundleLog"))
        return;

    char buffer[1024];
    size_t length = wkStringGetUTF8((WKStringRef)messageBody, buffer, sizeof(buffer));
    if (!length)
        return;
    buffer[sizeof(buffer) - 1] = '\0';
    NSLog(@"InjectedBundle: %s", buffer);
}

@interface WKWebView (MiniBrowserInjectedBundleBridge)
- (void)minibrowser_installInjectedBundleMessageBridge;
@end

@implementation WKWebView (MiniBrowserInjectedBundleBridge)

- (void)minibrowser_installInjectedBundleMessageBridge
{
    if (didInstallClient)
        return;
    resolveSymbols();
    if (!wkPageSetClient || !wkStringIsEqual || !wkStringGetUTF8) {
        NSLog(@"InjectedBundleMessageBridge: WebKit C APIs unavailable");
        return;
    }
    WKPageRef page = pageRefForWebView(self);
    if (!page) {
        NSLog(@"InjectedBundleMessageBridge: WKPageRef unavailable");
        return;
    }
    static WKPageInjectedBundleClientV0 client;
    client.base.version = 0;
    client.base.clientInfo = NULL;
    client.didReceiveMessageFromInjectedBundle = didReceiveMessageFromInjectedBundle;
    client.didReceiveSynchronousMessageFromInjectedBundle = NULL;
    wkPageSetClient(page, &client.base);
    didInstallClient = true;
    NSLog(@"InjectedBundleMessageBridge: registered page client");
}

@end
