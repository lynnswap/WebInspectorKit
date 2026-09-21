#import "WebInspectorNativeBridge.h"
#import "WebInspectorNativeABI.h"

#import <TargetConditionals.h>
#import <WebKit/WebKit.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <os/log.h>
#import <algorithm>
#import <atomic>
#import <memory>
#import <objc/runtime.h>
#import <vector>
#include <cstdlib>
#include <cxxabi.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

NSString *WebInspectorNativeDemangleCXXSymbol(const char *name)
{
    // Mach-O's symbol table adds an underscore to the Itanium external name.
    if (name[0] == '_' && name[1] == '_' && name[2] == 'Z')
        ++name;
    if (name[0] != '_' || name[1] != 'Z')
        return nil;
    std::unique_ptr<char, decltype(&std::free)> demangled(
        abi::__cxa_demangle(name, nullptr, nullptr, nullptr), &std::free);
    return demangled ? [NSString stringWithUTF8String:demangled.get()] : nil;
}

#if TARGET_OS_IPHONE || TARGET_OS_OSX
namespace WebInspectorNativeBridgePrivate {

using ConnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&, bool, bool);
using DisconnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&);

static constexpr ptrdiff_t invalidTargetOffset = -1;
static std::atomic<ptrdiff_t> cachedTargetOffset { invalidTargetOffset };

static NSString *const errorDomain = @"WebInspectorNativeBridge.Transport";

static os_log_t nativeBridgeLog()
{
    static os_log_t log = os_log_create("com.lynnswap.WebInspectorKit", "NativeBridge");
    return log;
}

enum ErrorCode : NSInteger {
    ErrorCodeUnsupported = 1,
    ErrorCodeAttachFailed = 2,
    ErrorCodeNotAttached = 3,
    ErrorCodeEncodingFailed = 4,
};

static constexpr uint8_t obfuscatedSymbolKey = 0xA7;

static NSString *deobfuscateXORBytes(const uint8_t *encodedBytes, size_t length)
{
    std::vector<char> decodedBytes(length + 1);
    for (size_t index = 0; index < length; ++index)
        decodedBytes[index] = static_cast<char>(encodedBytes[index] ^ obfuscatedSymbolKey);
    decodedBytes[length] = '\0';
    return [NSString stringWithUTF8String:decodedBytes.data()];
}

static SEL selectorFromXORBytes(const uint8_t *encodedBytes, size_t length)
{
    return NSSelectorFromString(deobfuscateXORBytes(encodedBytes, length));
}

static id objectResult(id target, SEL selector)
{
    if (![target respondsToSelector:selector])
        return nil;

    typedef id (*Getter)(id, SEL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL)
        return nil;

    Getter function = (Getter)implementation;
    return function(target, selector);
}

static BOOL invokeVoid(id target, SEL selector)
{
    if (![target respondsToSelector:selector])
        return NO;

    typedef void (*Invoker)(id, SEL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL)
        return NO;

    Invoker function = (Invoker)implementation;
    function(target, selector);
    return YES;
}

static NSError *makeError(ErrorCode code, NSString *description, NSString *details = nil)
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (details.length)
        userInfo[NSDebugDescriptionErrorKey] = details;
    return [NSError errorWithDomain:errorDomain code:code userInfo:userInfo];
}

static WebInspectorNativeResolvedSymbols emptyResolvedSymbols()
{
    return {
        .connectFrontendAddress = 0,
        .disconnectFrontendAddress = 0,
        .stringFromUTF8Address = 0,
        .stringImplToNSStringAddress = 0,
        .derefStringImplAddress = 0,
        .dispatchMessageFromRemoteAddress = 0,
        .debuggableVTableAddress = 0,
    };
}

static BOOL resolvedSymbolsAreComplete(WebInspectorNativeResolvedSymbols resolvedSymbols)
{
    return resolvedSymbols.connectFrontendAddress
        && resolvedSymbols.disconnectFrontendAddress
        && resolvedSymbols.stringFromUTF8Address
        && resolvedSymbols.stringImplToNSStringAddress
        && resolvedSymbols.derefStringImplAddress
        && resolvedSymbols.dispatchMessageFromRemoteAddress
        && resolvedSymbols.debuggableVTableAddress;
}

static NSString *missingResolvedSymbolNames(WebInspectorNativeResolvedSymbols resolvedSymbols)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (!resolvedSymbols.connectFrontendAddress)
        [names addObject:@"connectFrontend"];
    if (!resolvedSymbols.disconnectFrontendAddress)
        [names addObject:@"disconnectFrontend"];
    if (!resolvedSymbols.stringFromUTF8Address)
        [names addObject:@"stringFromUTF8"];
    if (!resolvedSymbols.stringImplToNSStringAddress)
        [names addObject:@"stringImplToNSString"];
    if (!resolvedSymbols.derefStringImplAddress)
        [names addObject:@"derefStringImpl"];
    if (!resolvedSymbols.dispatchMessageFromRemoteAddress)
        [names addObject:@"dispatchMessageFromRemote"];
    if (!resolvedSymbols.debuggableVTableAddress)
        [names addObject:@"debuggableVTable"];
    return [names componentsJoinedByString:@","];
}

static BOOL safeReadWord(const void *address, uintptr_t *valueOut)
{
    if (!address || !valueOut)
        return NO;

    uintptr_t rawValue = 0;
    vm_size_t bytesRead = 0;
    kern_return_t result = vm_read_overwrite(
        mach_task_self(),
        reinterpret_cast<vm_address_t>(address),
        sizeof(rawValue),
        reinterpret_cast<vm_address_t>(&rawValue),
        &bytesRead
    );
    if (result != KERN_SUCCESS || bytesRead != sizeof(rawValue)) {
        *valueOut = 0;
        return NO;
    }

    *valueOut = rawValue;
    return YES;
}

static BOOL safeReadPointer(const void *address, void **valueOut)
{
    if (!address || !valueOut)
        return NO;

    uintptr_t rawValue = 0;
    if (!safeReadWord(address, &rawValue)) {
        *valueOut = nullptr;
        return NO;
    }

    *valueOut = reinterpret_cast<void *>(rawValue);
    return YES;
}

struct PageStorage {
    __strong id owner { nil };
    void *page { nullptr };
    size_t bytes { 0 };
};

static void *pointerResult(id target, SEL selector)
{
    // WKObject is an NSProxy; use its concrete method rather than forwarding
    // NSObject's methodForSelector: through the proxy.
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!method)
        return nullptr;
    using Getter = void *(*)(id, SEL);
    auto getter = reinterpret_cast<Getter>(method_getImplementation(method));
    return getter(target, selector);
}

static PageStorage pageStorage(WKWebView *webView)
{
    // On Cocoa, WKPageRef is the Objective-C wrapper, whose _apiObject getter
    // returns the C++ page in its indexed storage. Query both through WebKit so
    // neither RefPtr storage nor the wrapper's alignment is replicated here.
    // Original: _pageForTesting
    const uint8_t pageName[] = { 0xF8, 0xD7, 0xC6, 0xC0, 0xC2, 0xE1, 0xC8, 0xD5, 0xF3, 0xC2, 0xD4, 0xD3, 0xCE, 0xC9, 0xC0 };
    id owner = (__bridge id)pointerResult(webView, selectorFromXORBytes(pageName, sizeof(pageName)));
    // Original: _apiObject
    const uint8_t objectName[] = { 0xF8, 0xC6, 0xD7, 0xCE, 0xE8, 0xC5, 0xCD, 0xC2, 0xC4, 0xD3 };
    void *page = pointerResult(owner, selectorFromXORBytes(objectName, sizeof(objectName)));
    if (!page)
        return { };

    const auto base = reinterpret_cast<uintptr_t>((__bridge void *)owner);
    const auto address = reinterpret_cast<uintptr_t>(page);
    const size_t allocationSize = malloc_size((__bridge const void *)owner);
    if (address < base || address - base >= allocationSize)
        return { };
    return { owner, page, allocationSize - (address - base) };
}

struct TargetResolution {
    void *target { nullptr };
    ptrdiff_t offset { invalidTargetOffset };
    size_t matches { 0 };
};

#if defined(__arm64__) && !__has_feature(ptrauth_calls)
__attribute__((target("pauth"), noinline))
static void *stripDataPointerAuthentication(void *pointer)
{
    // An arm64 client can inspect arm64e WebKit objects. ptrauth_strip is a
    // no-op in that client, so strip the data PAC for this identity comparison.
    __asm__("xpacd %0" : "+r"(pointer));
    return pointer;
}
#endif

static void *unsignedVTablePointer(void *pointer)
{
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_cxx_vtable_pointer);
#elif defined(__arm64__)
    static const bool supportsPointerAuthentication = [] {
        int supported = 0;
        size_t size = sizeof(supported);
        return sysctlbyname("hw.optional.arm.FEAT_PAuth", &supported, &size, nullptr, 0) == 0 && supported;
    }();
    return supportsPointerAuthentication ? stripDataPointerAuthentication(pointer) : pointer;
#else
    return pointer;
#endif
}

static void *targetAtOffset(void *page, size_t offset, uintptr_t vtableAddressPoint)
{
    void *target = nullptr;
    void *vtable = nullptr;
    if (!safeReadPointer(static_cast<uint8_t *>(page) + offset, &target) || !target
        || !safeReadPointer(target, &vtable))
        return nullptr;
    vtable = unsignedVTablePointer(vtable);
    return reinterpret_cast<uintptr_t>(vtable) == vtableAddressPoint ? target : nullptr;
}

static TargetResolution resolveTargetInPageProxy(void *page, size_t bytes, ptrdiff_t cachedOffset, uintptr_t vtableAddressPoint)
{
    if (!page || bytes < sizeof(void *) || !vtableAddressPoint)
        return { };
    if (cachedOffset >= 0 && static_cast<size_t>(cachedOffset) <= bytes - sizeof(void *)) {
        if (void *target = targetAtOffset(page, cachedOffset, vtableAddressPoint))
            return { target, cachedOffset, 1 };
    }
    TargetResolution result;
    for (size_t offset = 0; offset <= bytes - sizeof(void *); offset += sizeof(void *)) {
        void *candidate = targetAtOffset(page, offset, vtableAddressPoint);
        if (!candidate || candidate == result.target)
            continue;
        if (result.matches)
            return { nullptr, invalidTargetOffset, 2 };
        result = { candidate, static_cast<ptrdiff_t>(offset), 1 };
    }
    return result;
}

static TargetResolution resolveTarget(const PageStorage& storage, ptrdiff_t cachedOffset, uint64_t vtableSymbol)
{
    if (!vtableSymbol)
        return { };
    // WebPageDebuggable has a single nonvirtual inheritance chain. Its primary
    // Itanium vtable address point follows offset-to-top and typeinfo pointers.
    return resolveTargetInPageProxy(storage.page, storage.bytes, cachedOffset, vtableSymbol + 2 * sizeof(void *));
}

} // namespace WebInspectorNativeBridgePrivate

@interface WebInspectorNativeBridge ()

@property (nonatomic, weak, readonly) WKWebView *webView;
- (void)handleFrontendMessageString:(NSString *)messageString;
- (void)handleWebContentProcessTermination;
- (void)reconnectFrontendAfterWebContentProcessRelaunch;
- (void)reportFatalFailure:(NSString *)message;

@end

// Monocly uses these existing navigation callbacks to settle and persist history.
@protocol WebInspectorNativeNavigationDelegateClient <WKNavigationDelegate>
@optional
- (void)_webView:(WKWebView *)webView navigation:(nullable WKNavigation *)navigation didSameDocumentNavigation:(int64_t)navigationType;
- (void)_webView:(WKWebView *)webView backForwardListItemAdded:(nullable WKBackForwardListItem *)itemAdded removed:(nullable NSArray<WKBackForwardListItem *> *)itemsRemoved;
@end

@interface WebInspectorNativeNavigationDelegateProxy : NSObject <WKNavigationDelegate>

- (instancetype)initWithWebView:(WKWebView *)webView
                          bridge:(WebInspectorNativeBridge *)bridge
                          client:(nullable id<WKNavigationDelegate>)client;
- (void)installAsNavigationDelegate;
- (void)restoreClientAndInvalidate;

@end

static uint8_t navigationDelegateObservationContext;

class WebInspectorNativeFrontendChannel final : public Inspector::FrontendChannel {
public:
    WebInspectorNativeFrontendChannel(WebInspectorNativeBridge *owner, uint64_t stringImplToNSStringAddress)
        : m_owner(owner)
        , m_stringImplToNSStringAddress(stringImplToNSStringAddress)
    {
    }

    ConnectionType connectionType() const override
    {
#if TARGET_OS_OSX
        // WebInspectorKit drives its own frontend on macOS and does not create
        // WebKit's local inspector UI. Advertising this bridge as a remote
        // frontend avoids local-frontend side effects inside WebKit that can
        // destabilize the inspected page process during native attach.
        return ConnectionType::Remote;
#else
        return ConnectionType::Local;
#endif
    }

    void sendMessageToFrontend(const WTF::String& message) override
    {
        NSString *messageString = WebInspectorNativeABI::copyNSString(message, m_stringImplToNSStringAddress);
        __weak WebInspectorNativeBridge *owner = m_owner;
        dispatch_async(dispatch_get_main_queue(), ^{
            [owner handleFrontendMessageString:messageString];
        });
    }

private:
    __weak WebInspectorNativeBridge *m_owner;
    uint64_t m_stringImplToNSStringAddress { 0 };
};

@implementation WebInspectorNativeNavigationDelegateProxy {
    __weak WKWebView *_webView;
    __weak WebInspectorNativeBridge *_bridge;
    __weak id<WKNavigationDelegate> _client;
    BOOL _isObservingNavigationDelegate;
    BOOL _isUpdatingNavigationDelegate;
}

- (instancetype)initWithWebView:(WKWebView *)webView
                          bridge:(WebInspectorNativeBridge *)bridge
                          client:(id<WKNavigationDelegate>)client
{
    self = [super init];
    if (!self)
        return nil;

    _webView = webView;
    _bridge = bridge;
    _client = client;
    return self;
}

- (void)installAsNavigationDelegate
{
    WKWebView *webView = _webView;
    if (!webView || _isObservingNavigationDelegate)
        return;

    webView.navigationDelegate = self;
    [webView addObserver:self
              forKeyPath:@"navigationDelegate"
                 options:0
                 context:&navigationDelegateObservationContext];
    _isObservingNavigationDelegate = YES;
}

- (void)restoreClientAndInvalidate
{
    WKWebView *webView = _webView;
    if (_isObservingNavigationDelegate) {
        [webView removeObserver:self
                    forKeyPath:@"navigationDelegate"
                       context:&navigationDelegateObservationContext];
        _isObservingNavigationDelegate = NO;
    }
    if (webView.navigationDelegate == self)
        webView.navigationDelegate = _client;

    _webView = nil;
    _bridge = nil;
    _client = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context
{
    if (context != &navigationDelegateObservationContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (_isUpdatingNavigationDelegate)
        return;

    WKWebView *webView = _webView;
    if (!webView || webView.navigationDelegate == self)
        return;

    _client = webView.navigationDelegate;
    _isUpdatingNavigationDelegate = YES;
    webView.navigationDelegate = self;
    _isUpdatingNavigationDelegate = NO;
}

- (BOOL)respondsToSelector:(SEL)selector
{
    if (selector == @selector(webViewWebContentProcessDidTerminate:)
        || selector == @selector(webView:didStartProvisionalNavigation:)
        || selector == @selector(webView:didCommitNavigation:)
        || selector == @selector(webView:didFinishNavigation:))
        return YES;

    if (protocol_getMethodDescription(@protocol(WKNavigationDelegate), selector, NO, YES).name
        || protocol_getMethodDescription(@protocol(WebInspectorNativeNavigationDelegateClient), selector, NO, YES).name)
        return [super respondsToSelector:selector] && [_client respondsToSelector:selector];
    return [super respondsToSelector:selector];
}

// WebKit caches optional delegate capabilities when installing the delegate.
// Keep concrete entry points for callbacks queued before the weak client disappears.
- (void)_webView:(WKWebView *)webView navigation:(WKNavigation *)navigation didSameDocumentNavigation:(int64_t)navigationType
{
    id<WebInspectorNativeNavigationDelegateClient> client = (id)_client;
    if ([client respondsToSelector:_cmd])
        [client _webView:webView navigation:navigation didSameDocumentNavigation:navigationType];
}

- (void)_webView:(WKWebView *)webView backForwardListItemAdded:(WKBackForwardListItem *)itemAdded removed:(NSArray<WKBackForwardListItem *> *)itemsRemoved
{
    id<WebInspectorNativeNavigationDelegateClient> client = (id)_client;
    if ([client respondsToSelector:_cmd])
        [client _webView:webView backForwardListItemAdded:itemAdded removed:itemsRemoved];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView decidePolicyForNavigationAction:action decisionHandler:decisionHandler];
    else
        decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action preferences:(WKWebpagePreferences *)preferences decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd]) {
        [client webView:webView decidePolicyForNavigationAction:action preferences:preferences decisionHandler:decisionHandler];
    } else if ([client respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]) {
        [client webView:webView decidePolicyForNavigationAction:action decisionHandler:^(WKNavigationActionPolicy policy) {
            decisionHandler(policy, preferences);
        }];
    } else {
        decisionHandler(WKNavigationActionPolicyAllow, preferences);
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView decidePolicyForNavigationResponse:response decisionHandler:decisionHandler];
    else
        decisionHandler(response.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyCancel);
}

- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView didReceiveAuthenticationChallenge:challenge completionHandler:completionHandler];
    else
        completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
}

- (void)webView:(WKWebView *)webView authenticationChallenge:(NSURLAuthenticationChallenge *)challenge shouldAllowDeprecatedTLS:(void (^)(BOOL))decisionHandler
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView authenticationChallenge:challenge shouldAllowDeprecatedTLS:decisionHandler];
    else
        decisionHandler(NO);
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView didReceiveServerRedirectForProvisionalNavigation:navigation];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView didFailProvisionalNavigation:navigation withError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView didFailNavigation:navigation withError:error];
}

- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)download
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView navigationAction:action didBecomeDownload:download];
}

- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)response didBecomeDownload:(WKDownload *)download
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView navigationResponse:response didBecomeDownload:download];
}

- (void)webView:(WKWebView *)webView shouldGoToBackForwardListItem:(WKBackForwardListItem *)item willUseInstantBack:(BOOL)willUseInstantBack completionHandler:(void (^)(BOOL))completionHandler API_AVAILABLE(macos(26.0), ios(26.0))
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView shouldGoToBackForwardListItem:item willUseInstantBack:willUseInstantBack completionHandler:completionHandler];
    else
        completionHandler(YES);
}

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270000 || __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
- (void)webView:(WKWebView *)webView willSubmitForm:(WKFormInfo *)formInfo submissionHandler:(void (^)(void))submissionHandler API_AVAILABLE(macos(27.0), ios(27.0))
{
    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView willSubmitForm:formInfo submissionHandler:submissionHandler];
    else
        submissionHandler();
}
#endif

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    [_bridge handleWebContentProcessTermination];

    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webViewWebContentProcessDidTerminate:webView];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    [_bridge reconnectFrontendAfterWebContentProcessRelaunch];

    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView didStartProvisionalNavigation:navigation];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    [_bridge reconnectFrontendAfterWebContentProcessRelaunch];

    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView didCommitNavigation:navigation];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    [_bridge reconnectFrontendAfterWebContentProcessRelaunch];

    id<WKNavigationDelegate> client = _client;
    if ([client respondsToSelector:_cmd])
        [client webView:webView didFinishNavigation:navigation];
}

@end

@implementation WebInspectorNativeBridge {
    __weak WKWebView *_webView;
    id _inspector;
    void *_target;
    ptrdiff_t _targetOffset;
    uint64_t _disconnectFrontendAddress;
    WebInspectorNativeResolvedSymbols _resolvedSymbols;
    std::unique_ptr<WebInspectorNativeFrontendChannel> _frontendChannel;
    WebInspectorNativeNavigationDelegateProxy *_navigationDelegateProxy;
    BOOL _frontendAttached;
    BOOL _isAwaitingWebProcessRelaunch;
}

- (instancetype)initWithWebView:(WKWebView *)webView
{
    self = [super init];
    if (!self)
        return nil;

    _webView = webView;
    _targetOffset = WebInspectorNativeBridgePrivate::invalidTargetOffset;
    _resolvedSymbols = WebInspectorNativeBridgePrivate::emptyResolvedSymbols();
    return self;
}

- (WKWebView *)webView
{
    return _webView;
}

- (BOOL)attachedTargetIsStillValid
{
    if (!_target)
        return NO;

    __attribute__((objc_precise_lifetime)) WKWebView *webView = self.webView;
    if (!webView)
        return NO;

    auto storage = WebInspectorNativeBridgePrivate::pageStorage(webView);
    auto resolution = WebInspectorNativeBridgePrivate::resolveTarget(storage, _targetOffset, _resolvedSymbols.debuggableVTableAddress);
    return resolution.target == _target;
}

- (void)invalidateAttachmentState
{
    _frontendAttached = NO;
    _frontendChannel.reset();
    _disconnectFrontendAddress = 0;
    _resolvedSymbols = WebInspectorNativeBridgePrivate::emptyResolvedSymbols();
    _inspector = nil;
    _target = nullptr;
    _targetOffset = WebInspectorNativeBridgePrivate::invalidTargetOffset;
}

- (void)disconnectFrontendPreservingAttachmentState
{
    __attribute__((objc_precise_lifetime)) WKWebView *retainedView = self.webView;
    BOOL canDisconnectFrontend = NO;
    if (_frontendAttached && _frontendChannel && _target && _disconnectFrontendAddress)
        canDisconnectFrontend = [self attachedTargetIsStillValid];

    if (canDisconnectFrontend) {
        auto *disconnectFrontend = reinterpret_cast<WebInspectorNativeBridgePrivate::DisconnectFrontendFn>(
            static_cast<uintptr_t>(_disconnectFrontendAddress)
        );
        disconnectFrontend(_target, *_frontendChannel);
    }

    _frontendAttached = NO;
    _frontendChannel.reset();
}

- (BOOL)connectFrontendToCurrentWebProcess
{
    __attribute__((objc_precise_lifetime)) WKWebView *retainedView = self.webView;
    if (!WebInspectorNativeBridgePrivate::resolvedSymbolsAreComplete(_resolvedSymbols)
        || !_target
        || ![self attachedTargetIsStillValid])
        return NO;

    _frontendChannel = std::make_unique<WebInspectorNativeFrontendChannel>(
        self,
        _resolvedSymbols.stringImplToNSStringAddress
    );
    auto *connectFrontend = reinterpret_cast<WebInspectorNativeBridgePrivate::ConnectFrontendFn>(
        static_cast<uintptr_t>(_resolvedSymbols.connectFrontendAddress)
    );
    connectFrontend(_target, *_frontendChannel, false, false);
    _frontendAttached = YES;
    return YES;
}

- (void)installNavigationDelegateProxy
{
    __attribute__((objc_precise_lifetime)) WKWebView *webView = self.webView;
    if (!webView)
        return;

    _navigationDelegateProxy = [[WebInspectorNativeNavigationDelegateProxy alloc]
        initWithWebView:webView
                 bridge:self
                 client:webView.navigationDelegate];
    [_navigationDelegateProxy installAsNavigationDelegate];
}

- (void)removeNavigationDelegateProxy
{
    WebInspectorNativeNavigationDelegateProxy *proxy = _navigationDelegateProxy;
    if (!proxy)
        return;

    [proxy restoreClientAndInvalidate];
    _navigationDelegateProxy = nil;
}

- (void)dealloc
{
    [self detach];
}

- (BOOL)attachWithResolvedSymbols:(WebInspectorNativeResolvedSymbols)resolvedSymbols
                              error:(NSError * _Nullable __autoreleasing *)error
{
    __attribute__((objc_precise_lifetime)) WKWebView *retainedView = self.webView;
    [self detach];

    if (!self.webView) {
        NSError *transportError = WebInspectorNativeBridgePrivate::makeError(
            WebInspectorNativeBridgePrivate::ErrorCodeAttachFailed,
            @"WKWebView was released before attach."
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        return NO;
    }

    if ([self.webView.navigationDelegate isKindOfClass:WebInspectorNativeNavigationDelegateProxy.class]) {
        NSError *transportError = WebInspectorNativeBridgePrivate::makeError(
            WebInspectorNativeBridgePrivate::ErrorCodeAttachFailed,
            @"This WKWebView already has an attached native inspector."
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        return NO;
    }

    if (!WebInspectorNativeBridgePrivate::resolvedSymbolsAreComplete(resolvedSymbols)) {
        NSError *transportError = WebInspectorNativeBridgePrivate::makeError(
            WebInspectorNativeBridgePrivate::ErrorCodeUnsupported,
            @"Required runtime functions were unavailable.",
            WebInspectorNativeBridgePrivate::missingResolvedSymbolNames(resolvedSymbols)
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        return NO;
    }

    _disconnectFrontendAddress = resolvedSymbols.disconnectFrontendAddress;
    _resolvedSymbols = resolvedSymbols;

    // Original: _inspector
    static const uint8_t encodedInspectorSelectorName[] = { 0xF8, 0xCE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5 };
    SEL inspectorSelector = WebInspectorNativeBridgePrivate::selectorFromXORBytes(
        encodedInspectorSelectorName,
        sizeof(encodedInspectorSelectorName)
    );
    _inspector = WebInspectorNativeBridgePrivate::objectResult(self.webView, inspectorSelector);
    auto storage = WebInspectorNativeBridgePrivate::pageStorage(retainedView);
    ptrdiff_t preferredCachedOffset = _targetOffset;
    if (preferredCachedOffset == WebInspectorNativeBridgePrivate::invalidTargetOffset)
        preferredCachedOffset = WebInspectorNativeBridgePrivate::cachedTargetOffset.load();

    auto resolution = WebInspectorNativeBridgePrivate::resolveTarget(storage, preferredCachedOffset, resolvedSymbols.debuggableVTableAddress);
    _target = resolution.target;
    _targetOffset = resolution.offset;
    if (_targetOffset != WebInspectorNativeBridgePrivate::invalidTargetOffset)
        WebInspectorNativeBridgePrivate::cachedTargetOffset.store(_targetOffset);

#if TARGET_OS_OSX
    BOOL requiresInspectorConnection = NO;
#else
    BOOL requiresInspectorConnection = YES;
#endif

    SEL connectSelector = @selector(connect);
    if ((requiresInspectorConnection && (!_inspector || ![_inspector respondsToSelector:connectSelector])) || !_target) {
        NSError *transportError = WebInspectorNativeBridgePrivate::makeError(
            WebInspectorNativeBridgePrivate::ErrorCodeAttachFailed,
            @"The inspected page's native target was unavailable.");
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        [self detach];
        return NO;
    }

#if TARGET_OS_OSX
    // Transport-only attach should not create the local Web Inspector frontend on macOS.
    // Doing so spawns an extra frontend/WebContent path and destabilizes sandboxed hosts.
#else
    WebInspectorNativeBridgePrivate::invokeVoid(_inspector, connectSelector);
#endif

    if (![self connectFrontendToCurrentWebProcess]) {
        NSError *transportError = WebInspectorNativeBridgePrivate::makeError(
            WebInspectorNativeBridgePrivate::ErrorCodeAttachFailed,
            @"The inspector frontend could not connect to the current WebContent process."
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        [self detach];
        return NO;
    }
    _isAwaitingWebProcessRelaunch = NO;
    [self installNavigationDelegateProxy];
#if DEBUG
    os_log_info(WebInspectorNativeBridgePrivate::nativeBridgeLog(), "native inspector attach succeeded mode=remote-target");
#endif
    return YES;
}

- (BOOL)sendJSONString:(NSString *)message error:(NSError * _Nullable __autoreleasing *)error
{
    __attribute__((objc_precise_lifetime)) WKWebView *retainedView = self.webView;
    if (!WebInspectorNativeBridgePrivate::resolvedSymbolsAreComplete(_resolvedSymbols)) {
        [self invalidateAttachmentState];
        if (error) {
            *error = WebInspectorNativeBridgePrivate::makeError(
                WebInspectorNativeBridgePrivate::ErrorCodeUnsupported,
                @"Required runtime functions were unavailable."
            );
        }
        return NO;
    }
    if (!_target) {
        [self invalidateAttachmentState];
        if (error) {
            *error = WebInspectorNativeBridgePrivate::makeError(
                WebInspectorNativeBridgePrivate::ErrorCodeNotAttached,
                @"The inspected page's native target is unavailable."
            );
        }
        return NO;
    }
    if (![self attachedTargetIsStillValid]) {
        NSString *failureMessage = @"The inspected page's native target is unavailable.";
        [self invalidateAttachmentState];
        [self reportFatalFailure:failureMessage];
        if (error) {
            *error = WebInspectorNativeBridgePrivate::makeError(
                WebInspectorNativeBridgePrivate::ErrorCodeNotAttached,
                failureMessage
            );
        }
        return NO;
    }
    if (!message.length) {
        if (error) {
            *error = WebInspectorNativeBridgePrivate::makeError(
                WebInspectorNativeBridgePrivate::ErrorCodeEncodingFailed,
                @"The inspector message was empty."
            );
        }
        return NO;
    }

    WebInspectorNativeABI::ConstructedString payloadString(
        message,
        _resolvedSymbols.stringFromUTF8Address,
        _resolvedSymbols.derefStringImplAddress
    );
    WebInspectorNativeABI::dispatchToRemoteTarget(
        _target,
        payloadString.get(),
        _resolvedSymbols.dispatchMessageFromRemoteAddress
    );
    return YES;
}

- (void)detach
{
    [self removeNavigationDelegateProxy];
    [self disconnectFrontendPreservingAttachmentState];
    _isAwaitingWebProcessRelaunch = NO;
    [self invalidateAttachmentState];
}

- (void)handleWebContentProcessTermination
{
    if (_isAwaitingWebProcessRelaunch)
        return;

    _isAwaitingWebProcessRelaunch = YES;
    [self disconnectFrontendPreservingAttachmentState];
    WebInspectorNativeWebContentProcessTerminationHandler handler = self.webContentProcessTerminationHandler;
    if (handler)
        handler();
#if DEBUG
    os_log_info(WebInspectorNativeBridgePrivate::nativeBridgeLog(), "web content process terminated; inspector frontend disconnected");
#endif
}

- (void)reconnectFrontendAfterWebContentProcessRelaunch
{
    if (!_isAwaitingWebProcessRelaunch)
        return;

    if (![self connectFrontendToCurrentWebProcess])
        return;

    _isAwaitingWebProcessRelaunch = NO;
#if DEBUG
    os_log_info(WebInspectorNativeBridgePrivate::nativeBridgeLog(), "web content process relaunched; inspector frontend reconnected");
#endif
}

- (void)handleFrontendMessageString:(NSString *)messageString
{
    if (!messageString.length)
        return;

    WebInspectorNativeMessageHandler handler = self.messageHandler;
    if (handler)
        handler(messageString);
}

- (void)reportFatalFailure:(NSString *)message
{
    WebInspectorNativeFatalFailureHandler handler = self.fatalFailureHandler;
    if (handler)
        handler(message);
}

@end

WebInspectorNativeTargetDiscoveryTestResult WebInspectorNativeRunTargetDiscoveryForTesting(
    NSUInteger byteCount, NSInteger cachedOffset, NSInteger primaryOffset, NSInteger secondaryOffset, BOOL sameTarget)
{
    struct DummyTarget { virtual ~DummyTarget() = default; } first, second;
    std::vector<uint8_t> page(byteCount);
    auto set = [&](NSInteger offset, void *target) {
        if (offset >= 0 && byteCount >= sizeof(void *) && static_cast<size_t>(offset) <= byteCount - sizeof(void *))
            memcpy(page.data() + offset, &target, sizeof(target));
    };
    set(primaryOffset, &first);
    set(secondaryOffset, sameTarget ? &first : &second);
    void *vtable = nullptr;
    WebInspectorNativeBridgePrivate::safeReadPointer(&first, &vtable);
    vtable = WebInspectorNativeBridgePrivate::unsignedVTablePointer(vtable);
    auto result = WebInspectorNativeBridgePrivate::resolveTargetInPageProxy(page.data(), page.size(), cachedOffset, reinterpret_cast<uintptr_t>(vtable));
    return { !!result.target, result.offset, result.matches };
}

NSString *WebInspectorNativeRoundTripStringForTesting(NSString *string, WebInspectorNativeResolvedSymbols symbols)
{
    WebInspectorNativeABI::ConstructedString value(string, symbols.stringFromUTF8Address, symbols.derefStringImplAddress);
    return WebInspectorNativeABI::copyNSString(value.get(), symbols.stringImplToNSStringAddress);
}

void WebInspectorNativeDeliverFrontendMessageForTesting(
    WebInspectorNativeBridge *bridge,
    NSString *message
)
{
    [bridge handleFrontendMessageString:message];
}

#else

@implementation WebInspectorNativeBridge {
    __weak WKWebView *_webView;
}

- (instancetype)initWithWebView:(WKWebView *)webView
{
    self = [super init];
    if (!self)
        return nil;

    _webView = webView;
    return self;
}

- (BOOL)attachWithResolvedSymbols:(WebInspectorNativeResolvedSymbols)resolvedSymbols
                              error:(NSError * _Nullable __autoreleasing *)error
{
    (void)resolvedSymbols;
    if (error) {
        *error = [NSError errorWithDomain:@"WebInspectorNativeBridge.Transport"
                                     code:1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"Native inspector transport is only available on iOS and macOS." }];
    }
    return NO;
}

- (BOOL)sendJSONString:(NSString *)message error:(NSError * _Nullable __autoreleasing *)error
{
    __attribute__((objc_precise_lifetime)) WKWebView *retainedView = self.webView;
    if (error) {
        *error = [NSError errorWithDomain:@"WebInspectorNativeBridge.Transport"
                                     code:1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"Native inspector transport is only available on iOS and macOS." }];
    }
    return NO;
}

- (void)detach
{
}

@end

void WebInspectorNativeDeliverFrontendMessageForTesting(
    WebInspectorNativeBridge *bridge,
    NSString *message
)
{
    WebInspectorNativeMessageHandler handler = bridge.messageHandler;
    if (message.length && handler)
        handler(message);
}

#endif
