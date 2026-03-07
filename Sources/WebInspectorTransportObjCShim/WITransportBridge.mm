#import "WITransportBridge.h"
#import "WITransportInspectorABI.h"

#import <TargetConditionals.h>
#import <WebKit/WebKit.h>
#import <mach/mach.h>
#import <memory>
#import <objc/message.h>
#import <objc/runtime.h>

#if TARGET_OS_IPHONE || TARGET_OS_OSX
namespace WITransportBridgePrivate {

using ConnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&, bool, bool);
using DisconnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&);

static constexpr ptrdiff_t webPageInspectorControllerOffset = 0x4C0;
static constexpr size_t frontendRouterStorageIndex = 0;
static constexpr size_t backendDispatcherStorageIndex = 1;
static constexpr ptrdiff_t controllerCandidateOffsets[] = {
    webPageInspectorControllerOffset,
    webPageInspectorControllerOffset - 0x8,
    webPageInspectorControllerOffset + 0x8,
    webPageInspectorControllerOffset - 0x10,
    webPageInspectorControllerOffset + 0x10,
    webPageInspectorControllerOffset - 0x18,
    webPageInspectorControllerOffset + 0x18,
    webPageInspectorControllerOffset - 0x20,
    webPageInspectorControllerOffset + 0x20,
};

extern void backendDispatcherDispatch(void *, const WTF::String&) asm("__ZN9Inspector17BackendDispatcher8dispatchERKN3WTF6StringE");

static NSString *const errorDomain = @"WebInspectorTransport.Transport";

enum ErrorCode : NSInteger {
    ErrorCodeUnsupported = 1,
    ErrorCodeAttachFailed = 2,
    ErrorCodeNotAttached = 3,
    ErrorCodePageTargetUnavailable = 4,
    ErrorCodeEncodingFailed = 5,
};

static NSDictionary *dictionaryValue(id value)
{
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSString *stringValue(id value)
{
    if ([value isKindOfClass:NSString.class])
        return value;
    if ([value respondsToSelector:@selector(stringValue)])
        return [value stringValue];
    return nil;
}

static NSError *makeError(ErrorCode code, NSString *description, NSString *details = nil)
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (details.length)
        userInfo[NSDebugDescriptionErrorKey] = details;
    return [NSError errorWithDomain:errorDomain code:code userInfo:userInfo];
}

static BOOL safeReadPointer(const void *address, void **valueOut)
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
        *valueOut = nullptr;
        return NO;
    }

    *valueOut = reinterpret_cast<void *>(rawValue);
    return YES;
}

static BOOL pointerIsWritableMapped(const void *pointer)
{
    if (!pointer)
        return NO;

    vm_address_t regionAddress = static_cast<vm_address_t>(reinterpret_cast<uintptr_t>(pointer));
    vm_size_t regionSize = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t result = vm_region_recurse_64(
        mach_task_self(),
        &regionAddress,
        &regionSize,
        &depth,
        reinterpret_cast<vm_region_recurse_info_t>(&info),
        &infoCount
    );
    if (result != KERN_SUCCESS)
        return NO;

    vm_address_t pointerAddress = static_cast<vm_address_t>(reinterpret_cast<uintptr_t>(pointer));
    if (pointerAddress < regionAddress || pointerAddress >= regionAddress + regionSize)
        return NO;

    vm_prot_t requiredProtection = VM_PROT_READ | VM_PROT_WRITE;
    return (info.protection & requiredProtection) == requiredProtection;
}

static ptrdiff_t ivarOffset(Class cls, const char *name)
{
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar ? ivar_getOffset(ivar) : NSNotFound;
}

static id invokeObjectGetter(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    using Getter = id (*)(id, SEL);
    return reinterpret_cast<Getter>(objc_msgSend)(target, selector);
}

static BOOL invokeVoid(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return NO;

    using Invoker = void (*)(id, SEL);
    reinterpret_cast<Invoker>(objc_msgSend)(target, selector);
    return YES;
}

static void *pageProxyPointer(WKWebView *webView)
{
    ptrdiff_t offset = ivarOffset(WKWebView.class, "_page");
    if (offset == NSNotFound)
        return nullptr;

    auto *storage = reinterpret_cast<uint8_t *>((__bridge void *)webView) + offset;
    void *page = nullptr;
    return safeReadPointer(storage, &page) ? page : nullptr;
}

static BOOL backendDispatcherPointer(void *controller, void **backendDispatcherOut)
{
    if (!controller || !backendDispatcherOut)
        return NO;

    auto *slot = reinterpret_cast<void **>(controller) + backendDispatcherStorageIndex;
    return safeReadPointer(slot, backendDispatcherOut) && *backendDispatcherOut;
}

static BOOL frontendRouterPointer(void *controller, void **frontendRouterOut)
{
    if (!controller || !frontendRouterOut)
        return NO;

    auto *slot = reinterpret_cast<void **>(controller) + frontendRouterStorageIndex;
    return safeReadPointer(slot, frontendRouterOut) && *frontendRouterOut;
}

static BOOL controllerCandidateAtOffset(void *pageProxy, ptrdiff_t offset, void **controllerOut, void **backendDispatcherOut)
{
    if (!pageProxy)
        return NO;

    auto *slot = reinterpret_cast<uint8_t *>(pageProxy) + offset;
    void *controller = nullptr;
    if (!safeReadPointer(slot, &controller) || !controller || !pointerIsWritableMapped(controller))
        return NO;

    void *frontendRouter = nullptr;
    if (!frontendRouterPointer(controller, &frontendRouter) || !frontendRouter || !pointerIsWritableMapped(frontendRouter))
        return NO;

    void *backendDispatcher = nullptr;
    if (!backendDispatcherPointer(controller, &backendDispatcher) || !backendDispatcher || !pointerIsWritableMapped(backendDispatcher))
        return NO;

    if (controllerOut)
        *controllerOut = controller;
    if (backendDispatcherOut)
        *backendDispatcherOut = backendDispatcher;
    return YES;
}

static NSError *selectorFailureError(id inspectorObject, void *pageProxy, void *controller, void *backendDispatcher)
{
    if (!inspectorObject)
        return makeError(ErrorCodeAttachFailed, @"WKWebView._inspector was unavailable.");
    if (!pageProxy)
        return makeError(ErrorCodeAttachFailed, @"Unable to resolve WebPageProxy from WKWebView.");
    if (!controller)
        return makeError(ErrorCodeAttachFailed, @"Unable to resolve WebPageInspectorController from WebPageProxy.");
    if (!backendDispatcher)
        return makeError(ErrorCodeAttachFailed, @"Unable to resolve Inspector::BackendDispatcher from WebPageInspectorController.");
    return makeError(ErrorCodeAttachFailed, @"Required private selectors or inspector controller state were unavailable.");
}

} // namespace WITransportBridgePrivate

@interface WITransportBridge ()

@property (nonatomic, weak, readonly) WKWebView *webView;
- (void)handleFrontendMessageString:(NSString *)messageString;
- (void)reportFatalFailure:(NSString *)message;

@end

class WITransportFrontendChannel final : public Inspector::FrontendChannel {
public:
    explicit WITransportFrontendChannel(WITransportBridge *owner)
        : m_owner(owner)
    {
    }

    ConnectionType connectionType() const override
    {
        return ConnectionType::Local;
    }

    void sendMessageToFrontend(const WTF::String& message) override
    {
        NSString *messageString = WITransportInspectorABI::copyNSString(message);
        __weak WITransportBridge *owner = m_owner;
        dispatch_async(dispatch_get_main_queue(), ^{
            [owner handleFrontendMessageString:messageString];
        });
    }

private:
    __weak WITransportBridge *m_owner;
};

@implementation WITransportBridge {
    __weak WKWebView *_webView;
    id _inspector;
    void *_controller;
    void *_backendDispatcher;
    WITransportBridgePrivate::DisconnectFrontendFn _disconnectFrontend;
    std::unique_ptr<WITransportFrontendChannel> _frontendChannel;
    BOOL _frontendAttached;
}

- (instancetype)initWithWebView:(WKWebView *)webView
{
    self = [super init];
    if (!self)
        return nil;

    _webView = webView;
    return self;
}

- (WKWebView *)webView
{
    return _webView;
}

- (void)dealloc
{
    [self detach];
}

- (BOOL)attachWithConnectFrontendAddress:(uint64_t)connectFrontendAddress
              disconnectFrontendAddress:(uint64_t)disconnectFrontendAddress
                                  error:(NSError * _Nullable __autoreleasing *)error
{
    [self detach];

    if (!self.webView) {
        NSError *transportError = WITransportBridgePrivate::makeError(
            WITransportBridgePrivate::ErrorCodeAttachFailed,
            @"WKWebView was released before attach."
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        return NO;
    }

    if (!connectFrontendAddress || !disconnectFrontendAddress) {
        NSError *transportError = WITransportBridgePrivate::makeError(
            WITransportBridgePrivate::ErrorCodeUnsupported,
            @"connect/disconnect symbols were unavailable."
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        return NO;
    }

    using ConnectFrontendFn = WITransportBridgePrivate::ConnectFrontendFn;
    using DisconnectFrontendFn = WITransportBridgePrivate::DisconnectFrontendFn;

    auto *connectFrontend = reinterpret_cast<ConnectFrontendFn>(static_cast<uintptr_t>(connectFrontendAddress));
    _disconnectFrontend = reinterpret_cast<DisconnectFrontendFn>(static_cast<uintptr_t>(disconnectFrontendAddress));

    _inspector = WITransportBridgePrivate::invokeObjectGetter(self.webView, @"_inspector");
    void *page = WITransportBridgePrivate::pageProxyPointer(self.webView);
    void *controller = nullptr;
    void *backendDispatcher = nullptr;
    NSUInteger nearbyValidCandidateCount = 0;

    for (ptrdiff_t candidateOffset : WITransportBridgePrivate::controllerCandidateOffsets) {
        void *candidateController = nullptr;
        void *candidateBackendDispatcher = nullptr;
        BOOL valid = WITransportBridgePrivate::controllerCandidateAtOffset(page, candidateOffset, &candidateController, &candidateBackendDispatcher);
        if (!valid)
            continue;

        if (candidateOffset == WITransportBridgePrivate::webPageInspectorControllerOffset) {
            controller = candidateController;
            backendDispatcher = candidateBackendDispatcher;
            break;
        }

        nearbyValidCandidateCount++;
        if (nearbyValidCandidateCount == 1) {
            controller = candidateController;
            backendDispatcher = candidateBackendDispatcher;
        } else {
            controller = nullptr;
            backendDispatcher = nullptr;
        }
    }

    _controller = controller;
    _backendDispatcher = backendDispatcher;

    if (!_inspector || !_controller || !_backendDispatcher) {
        NSError *transportError = WITransportBridgePrivate::selectorFailureError(_inspector, page, controller, backendDispatcher);
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        [self detach];
        return NO;
    }

    if (!WITransportBridgePrivate::invokeVoid(_inspector, @"connect")) {
        NSError *transportError = WITransportBridgePrivate::makeError(
            WITransportBridgePrivate::ErrorCodeAttachFailed,
            @"_WKInspector.connect was unavailable."
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        [self detach];
        return NO;
    }

    _frontendChannel = std::make_unique<WITransportFrontendChannel>(self);
    connectFrontend(_controller, *_frontendChannel, false, false);
    _frontendAttached = YES;
    return YES;
}

- (BOOL)sendRootJSONString:(NSString *)message error:(NSError * _Nullable __autoreleasing *)error
{
    if (!_backendDispatcher) {
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeNotAttached,
                @"The root BackendDispatcher is unavailable."
            );
        }
        return NO;
    }
    if (!message.length) {
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeEncodingFailed,
                @"The root inspector message was empty."
            );
        }
        return NO;
    }

    WITransportInspectorABI::ConstructedString payloadString(message);
    WITransportBridgePrivate::backendDispatcherDispatch(_backendDispatcher, payloadString.get());
    return YES;
}

- (BOOL)sendPageJSONString:(NSString *)message
          targetIdentifier:(NSString *)targetIdentifier
           outerIdentifier:(NSNumber *)outerIdentifier
                     error:(NSError * _Nullable __autoreleasing *)error
{
    if (!targetIdentifier.length) {
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodePageTargetUnavailable,
                @"The page target identifier was unavailable."
            );
        }
        return NO;
    }
    if (!message.length) {
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeEncodingFailed,
                @"The page inspector message was empty."
            );
        }
        return NO;
    }

    NSError *serializationError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"id": outerIdentifier,
        @"method": @"Target.sendMessageToTarget",
        @"params": @{
            @"targetId": targetIdentifier,
            @"message": message,
        },
    } options:0 error:&serializationError];

    if (!data || serializationError) {
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeEncodingFailed,
                serializationError.localizedDescription ?: @"Failed to encode the page inspector wrapper command."
            );
        }
        return NO;
    }

    NSString *jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!jsonString.length) {
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeEncodingFailed,
                @"The page inspector wrapper command could not be converted to UTF-8."
            );
        }
        return NO;
    }

    return [self sendRootJSONString:jsonString error:error];
}

- (void)detach
{
    if (_frontendAttached && _frontendChannel && _controller && _disconnectFrontend)
        _disconnectFrontend(_controller, *_frontendChannel);

    _frontendAttached = NO;
    _frontendChannel.reset();
    _disconnectFrontend = nullptr;
    _inspector = nil;
    _controller = nullptr;
    _backendDispatcher = nullptr;
}

- (void)handleFrontendMessageString:(NSString *)messageString
{
    if (!messageString.length)
        return;

    WITransportRootMessageHandler rootHandler = self.rootMessageHandler;
    if (rootHandler)
        rootHandler(messageString);

    NSData *payloadData = [messageString dataUsingEncoding:NSUTF8StringEncoding];
    if (!payloadData)
        return;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:&error];
    NSDictionary *message = WITransportBridgePrivate::dictionaryValue(json);
    if (!message || error)
        return;

    NSString *method = WITransportBridgePrivate::stringValue(message[@"method"]);
    NSDictionary *params = WITransportBridgePrivate::dictionaryValue(message[@"params"]);
    if (![method isEqualToString:@"Target.dispatchMessageFromTarget"] || !params)
        return;

    NSString *targetIdentifier = WITransportBridgePrivate::stringValue(params[@"targetId"]);
    NSString *pageMessageString = WITransportBridgePrivate::stringValue(params[@"message"]);
    if (!targetIdentifier.length || !pageMessageString.length)
        return;

    WITransportPageMessageHandler pageHandler = self.pageMessageHandler;
    if (pageHandler)
        pageHandler(pageMessageString, targetIdentifier);
}

- (void)reportFatalFailure:(NSString *)message
{
    WITransportFatalFailureHandler handler = self.fatalFailureHandler;
    if (handler)
        handler(message);
}

@end

#else

@implementation WITransportBridge {
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

- (BOOL)attachWithConnectFrontendAddress:(uint64_t)connectFrontendAddress
              disconnectFrontendAddress:(uint64_t)disconnectFrontendAddress
                                  error:(NSError * _Nullable __autoreleasing *)error
{
    if (error) {
        *error = [NSError errorWithDomain:@"WebInspectorTransport.Transport"
                                     code:1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"WebInspectorTransport is only available on iOS and macOS." }];
    }
    return NO;
}

- (BOOL)sendRootJSONString:(NSString *)message error:(NSError * _Nullable __autoreleasing *)error
{
    if (error) {
        *error = [NSError errorWithDomain:@"WebInspectorTransport.Transport"
                                     code:1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"WebInspectorTransport is only available on iOS and macOS." }];
    }
    return NO;
}

- (BOOL)sendPageJSONString:(NSString *)message
          targetIdentifier:(NSString *)targetIdentifier
           outerIdentifier:(NSNumber *)outerIdentifier
                     error:(NSError * _Nullable __autoreleasing *)error
{
    if (error) {
        *error = [NSError errorWithDomain:@"WebInspectorTransport.Transport"
                                     code:1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"WebInspectorTransport is only available on iOS and macOS." }];
    }
    return NO;
}

- (void)detach
{
}

@end

#endif
