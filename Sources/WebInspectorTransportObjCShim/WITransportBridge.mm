#import "WITransportBridge.h"
#import "WITransportInspectorABI.h"

#import <TargetConditionals.h>
#import <WebKit/WebKit.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <algorithm>
#import <atomic>
#import <memory>
#import <objc/message.h>
#import <objc/runtime.h>
#import <vector>

#if TARGET_OS_IPHONE || TARGET_OS_OSX
namespace WITransportBridgePrivate {

using ConnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&, bool, bool);
using DisconnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&);

static constexpr ptrdiff_t invalidControllerOffset = -1;
static constexpr ptrdiff_t webPageInspectorControllerOffset = 0x4C0;
static constexpr size_t frontendRouterStorageIndex = 0;
static constexpr size_t backendDispatcherStorageIndex = 1;
static constexpr ptrdiff_t preferredControllerSearchRadius = 0x100;
static constexpr size_t fallbackControllerScanBytes = 0x1000;
static std::atomic<ptrdiff_t> cachedControllerOffset { invalidControllerOffset };

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

static WITransportResolvedFunctions emptyResolvedFunctions()
{
    return {
        .connectFrontendAddress = 0,
        .disconnectFrontendAddress = 0,
        .stringFromUTF8Address = 0,
        .stringImplToNSStringAddress = 0,
        .destroyStringImplAddress = 0,
        .backendDispatcherDispatchAddress = 0,
    };
}

static BOOL resolvedFunctionsAreComplete(WITransportResolvedFunctions resolvedFunctions)
{
    return resolvedFunctions.connectFrontendAddress
        && resolvedFunctions.disconnectFrontendAddress
        && resolvedFunctions.stringFromUTF8Address
        && resolvedFunctions.stringImplToNSStringAddress
        && resolvedFunctions.destroyStringImplAddress
        && resolvedFunctions.backendDispatcherDispatchAddress;
}

static NSString *missingResolvedFunctionNames(WITransportResolvedFunctions resolvedFunctions)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (!resolvedFunctions.connectFrontendAddress)
        [names addObject:@"connectFrontend"];
    if (!resolvedFunctions.disconnectFrontendAddress)
        [names addObject:@"disconnectFrontend"];
    if (!resolvedFunctions.stringFromUTF8Address)
        [names addObject:@"stringFromUTF8"];
    if (!resolvedFunctions.stringImplToNSStringAddress)
        [names addObject:@"stringImplToNSString"];
    if (!resolvedFunctions.destroyStringImplAddress)
        [names addObject:@"destroyStringImpl"];
    if (!resolvedFunctions.backendDispatcherDispatchAddress)
        [names addObject:@"backendDispatcherDispatch"];
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

struct ControllerResolutionStats {
    size_t attemptedOffsetCount { 0 };
    size_t validCandidateCount { 0 };
    size_t scannedByteCount { 0 };
    ptrdiff_t resolvedOffset { invalidControllerOffset };
    bool usedFallbackRange { false };
    std::vector<ptrdiff_t> candidateOffsets;
};

struct ControllerResolutionResult {
    void *controller { nullptr };
    void *backendDispatcher { nullptr };
    ControllerResolutionStats stats;
};

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

static BOOL frontendRouterPointer(void *controller, void **frontendRouterOut)
{
    if (!controller || !frontendRouterOut)
        return NO;

    auto *slot = reinterpret_cast<void **>(controller) + frontendRouterStorageIndex;
    return safeReadPointer(slot, frontendRouterOut) && *frontendRouterOut;
}

static BOOL backendDispatcherPointer(void *controller, void **backendDispatcherOut)
{
    if (!controller || !backendDispatcherOut)
        return NO;

    auto *slot = reinterpret_cast<void **>(controller) + backendDispatcherStorageIndex;
    return safeReadPointer(slot, backendDispatcherOut) && *backendDispatcherOut;
}

static BOOL controllerCandidateAtOffset(void *pageProxy, ptrdiff_t offset, void **controllerOut, void **backendDispatcherOut)
{
    if (!pageProxy)
        return NO;
    if (offset < 0)
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

static size_t resolvedControllerScanByteCount(void *pageProxy, bool *usedFallbackRangeOut)
{
    bool usedFallbackRange = false;
    size_t scanByteCount = pageProxy ? malloc_size(pageProxy) : 0;
    if (!scanByteCount) {
        scanByteCount = fallbackControllerScanBytes;
        usedFallbackRange = true;
    }

    if (usedFallbackRangeOut)
        *usedFallbackRangeOut = usedFallbackRange;
    return scanByteCount;
}

static void appendUniqueCandidateOffset(std::vector<ptrdiff_t>& offsets, ptrdiff_t offset, size_t scanByteCount)
{
    if (offset < 0)
        return;

    size_t normalizedOffset = static_cast<size_t>(offset);
    if (normalizedOffset + sizeof(void *) > scanByteCount)
        return;
    if (normalizedOffset % sizeof(void *) != 0)
        return;
    if (std::find(offsets.begin(), offsets.end(), offset) != offsets.end())
        return;

    offsets.push_back(offset);
}

static ControllerResolutionResult resolveControllerInPageProxy(
    void *pageProxy,
    size_t scanByteCount,
    bool usedFallbackRange,
    ptrdiff_t preferredCachedOffset
)
{
    ControllerResolutionResult result;
    result.stats.scannedByteCount = scanByteCount;
    result.stats.usedFallbackRange = usedFallbackRange;

    if (!pageProxy || scanByteCount < sizeof(void *))
        return result;

    if (preferredCachedOffset != invalidControllerOffset) {
        result.stats.attemptedOffsetCount = 1;
        if (controllerCandidateAtOffset(pageProxy, preferredCachedOffset, &result.controller, &result.backendDispatcher)) {
            result.stats.validCandidateCount = 1;
            result.stats.resolvedOffset = preferredCachedOffset;
            return result;
        }
    }

    std::vector<ptrdiff_t> preferredOffsets;
    preferredOffsets.reserve((preferredControllerSearchRadius * 2) / sizeof(void *) + 1);
    for (ptrdiff_t delta = -preferredControllerSearchRadius; delta <= preferredControllerSearchRadius; delta += sizeof(void *))
        appendUniqueCandidateOffset(preferredOffsets, webPageInspectorControllerOffset + delta, scanByteCount);

    void *uniqueController = nullptr;
    void *uniqueBackendDispatcher = nullptr;
    ptrdiff_t uniqueOffset = invalidControllerOffset;

    auto registerCandidate = [&](ptrdiff_t offset, void *controller, void *backendDispatcher) {
        result.stats.validCandidateCount += 1;
        result.stats.candidateOffsets.push_back(offset);
        if (result.stats.validCandidateCount == 1) {
            uniqueOffset = offset;
            uniqueController = controller;
            uniqueBackendDispatcher = backendDispatcher;
            return;
        }

        uniqueOffset = invalidControllerOffset;
        uniqueController = nullptr;
        uniqueBackendDispatcher = nullptr;
    };

    for (ptrdiff_t offset : preferredOffsets) {
        result.stats.attemptedOffsetCount += 1;

        void *candidateController = nullptr;
        void *candidateBackendDispatcher = nullptr;
        if (!controllerCandidateAtOffset(pageProxy, offset, &candidateController, &candidateBackendDispatcher))
            continue;

        registerCandidate(offset, candidateController, candidateBackendDispatcher);
    }

    if (result.stats.validCandidateCount != 1) {
        for (size_t rawOffset = 0; rawOffset + sizeof(void *) <= scanByteCount; rawOffset += sizeof(void *)) {
            ptrdiff_t offset = static_cast<ptrdiff_t>(rawOffset);
            if (std::find(preferredOffsets.begin(), preferredOffsets.end(), offset) != preferredOffsets.end())
                continue;

            result.stats.attemptedOffsetCount += 1;

            void *candidateController = nullptr;
            void *candidateBackendDispatcher = nullptr;
            if (!controllerCandidateAtOffset(pageProxy, offset, &candidateController, &candidateBackendDispatcher))
                continue;

            registerCandidate(offset, candidateController, candidateBackendDispatcher);
        }
    }

    if (result.stats.validCandidateCount == 1) {
        result.controller = uniqueController;
        result.backendDispatcher = uniqueBackendDispatcher;
        result.stats.resolvedOffset = uniqueOffset;
    }

    return result;
}

static ControllerResolutionResult resolveControllerInPageProxy(void *pageProxy, ptrdiff_t preferredCachedOffset)
{
    bool usedFallbackRange = false;
    size_t scanByteCount = resolvedControllerScanByteCount(pageProxy, &usedFallbackRange);
    return resolveControllerInPageProxy(pageProxy, scanByteCount, usedFallbackRange, preferredCachedOffset);
}

static NSString *controllerResolutionDiagnosticsString(const ControllerResolutionStats& stats)
{
    NSMutableArray<NSString *> *candidateOffsets = [NSMutableArray arrayWithCapacity:stats.candidateOffsets.size()];
    for (ptrdiff_t offset : stats.candidateOffsets)
        [candidateOffsets addObject:[NSString stringWithFormat:@"%td", offset]];

    return [NSString stringWithFormat:
        @"page_allocation_size=%zu attempted_offsets=%zu valid_candidates=%zu candidate_offsets=[%@] used_fallback_range=%@ resolved_offset=%td",
        stats.scannedByteCount,
        stats.attemptedOffsetCount,
        stats.validCandidateCount,
        [candidateOffsets componentsJoinedByString:@","],
        stats.usedFallbackRange ? @"true" : @"false",
        stats.resolvedOffset
    ];
}

static void freeAllocatedBlocks(std::vector<void *>& allocations)
{
    for (auto it = allocations.rbegin(); it != allocations.rend(); ++it)
        free(*it);
    allocations.clear();
}

static void *allocateZeroedBlock(size_t byteCount, std::vector<void *>& allocations)
{
    void *block = malloc(byteCount);
    if (!block)
        return nullptr;

    memset(block, 0, byteCount);
    allocations.push_back(block);
    return block;
}

static BOOL installSyntheticControllerAtOffset(
    void *pageBuffer,
    size_t pageByteCount,
    NSInteger offset,
    std::vector<void *>& allocations
)
{
    if (!pageBuffer || offset < 0)
        return NO;

    size_t normalizedOffset = static_cast<size_t>(offset);
    if (normalizedOffset + sizeof(void *) > pageByteCount)
        return NO;

    void *controller = allocateZeroedBlock(sizeof(uintptr_t) * 5, allocations);
    void *frontendRouter = allocateZeroedBlock(sizeof(uint64_t), allocations);
    void *backendDispatcher = allocateZeroedBlock(sizeof(uint64_t), allocations);
    void *agentsBuffer = allocateZeroedBlock(sizeof(uint64_t), allocations);
    if (!controller || !frontendRouter || !backendDispatcher || !agentsBuffer)
        return NO;

    auto *controllerWords = reinterpret_cast<uintptr_t *>(controller);
    controllerWords[0] = reinterpret_cast<uintptr_t>(frontendRouter);
    controllerWords[1] = reinterpret_cast<uintptr_t>(backendDispatcher);
    controllerWords[2] = reinterpret_cast<uintptr_t>(agentsBuffer);
    controllerWords[3] = 1;
    controllerWords[4] = 1;

    auto *slot = reinterpret_cast<void **>(reinterpret_cast<uint8_t *>(pageBuffer) + normalizedOffset);
    *slot = controller;
    return YES;
}

static NSError *selectorFailureError(
    id inspectorObject,
    void *pageProxy,
    void *controller,
    void *backendDispatcher,
    const ControllerResolutionStats& controllerResolutionStats
)
{
    NSString *diagnostics = controllerResolutionDiagnosticsString(controllerResolutionStats);
#if !TARGET_OS_OSX
    if (!inspectorObject)
        return makeError(ErrorCodeAttachFailed, @"WKWebView._inspector was unavailable.", diagnostics);
#else
    (void)inspectorObject;
#endif
    if (!pageProxy)
        return makeError(ErrorCodeAttachFailed, @"Unable to resolve WebPageProxy from WKWebView.", diagnostics);
    if (!controller)
        return makeError(ErrorCodeAttachFailed, @"Unable to resolve WebPageInspectorController from WebPageProxy.", diagnostics);
    if (!backendDispatcher)
        return makeError(ErrorCodeAttachFailed, @"Unable to resolve Inspector::BackendDispatcher from WebPageInspectorController.", diagnostics);
    return makeError(
        ErrorCodeAttachFailed,
        @"Required private selectors or inspector controller state were unavailable.",
        diagnostics
    );
}

} // namespace WITransportBridgePrivate

@interface WITransportBridge ()

@property (nonatomic, weak, readonly) WKWebView *webView;
- (void)handleFrontendMessageString:(NSString *)messageString;
- (void)reportFatalFailure:(NSString *)message;

@end

class WITransportFrontendChannel final : public Inspector::FrontendChannel {
public:
    WITransportFrontendChannel(WITransportBridge *owner, uint64_t stringImplToNSStringAddress)
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
        NSString *messageString = WITransportInspectorABI::copyNSString(message, m_stringImplToNSStringAddress);
        __weak WITransportBridge *owner = m_owner;
        dispatch_async(dispatch_get_main_queue(), ^{
            [owner handleFrontendMessageString:messageString];
        });
    }

private:
    __weak WITransportBridge *m_owner;
    uint64_t m_stringImplToNSStringAddress { 0 };
};

@implementation WITransportBridge {
    __weak WKWebView *_webView;
    id _inspector;
    void *_controller;
    void *_backendDispatcher;
    ptrdiff_t _controllerOffset;
    WITransportBridgePrivate::DisconnectFrontendFn _disconnectFrontend;
    WITransportResolvedFunctions _resolvedFunctions;
    std::unique_ptr<WITransportFrontendChannel> _frontendChannel;
    BOOL _frontendAttached;
}

- (instancetype)initWithWebView:(WKWebView *)webView
{
    self = [super init];
    if (!self)
        return nil;

    _webView = webView;
    _controllerOffset = WITransportBridgePrivate::invalidControllerOffset;
    _resolvedFunctions = WITransportBridgePrivate::emptyResolvedFunctions();
    return self;
}

- (WKWebView *)webView
{
    return _webView;
}

- (BOOL)attachedControllerIsStillValid
{
    if (!_controller || !_backendDispatcher)
        return NO;

    WKWebView *webView = self.webView;
    if (!webView)
        return NO;

    void *page = WITransportBridgePrivate::pageProxyPointer(webView);
    if (!page)
        return NO;

    auto resolution = WITransportBridgePrivate::resolveControllerInPageProxy(page, _controllerOffset);
    return resolution.controller == _controller && resolution.backendDispatcher == _backendDispatcher;
}

- (void)invalidateAttachmentState
{
    _frontendAttached = NO;
    _frontendChannel.reset();
    _disconnectFrontend = nullptr;
    _resolvedFunctions = WITransportBridgePrivate::emptyResolvedFunctions();
    _inspector = nil;
    _controller = nullptr;
    _backendDispatcher = nullptr;
    _controllerOffset = WITransportBridgePrivate::invalidControllerOffset;
}

- (void)dealloc
{
    [self detach];
}

- (BOOL)attachWithResolvedFunctions:(WITransportResolvedFunctions)resolvedFunctions
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

    if (!WITransportBridgePrivate::resolvedFunctionsAreComplete(resolvedFunctions)) {
        NSError *transportError = WITransportBridgePrivate::makeError(
            WITransportBridgePrivate::ErrorCodeUnsupported,
            @"Required runtime functions were unavailable.",
            WITransportBridgePrivate::missingResolvedFunctionNames(resolvedFunctions)
        );
        if (error)
            *error = transportError;
        [self reportFatalFailure:transportError.localizedDescription];
        return NO;
    }

    using ConnectFrontendFn = WITransportBridgePrivate::ConnectFrontendFn;
    using DisconnectFrontendFn = WITransportBridgePrivate::DisconnectFrontendFn;

    auto *connectFrontend = reinterpret_cast<ConnectFrontendFn>(static_cast<uintptr_t>(resolvedFunctions.connectFrontendAddress));
    _disconnectFrontend = reinterpret_cast<DisconnectFrontendFn>(static_cast<uintptr_t>(resolvedFunctions.disconnectFrontendAddress));
    _resolvedFunctions = resolvedFunctions;

    _inspector = WITransportBridgePrivate::invokeObjectGetter(self.webView, @"_inspector");
    void *page = WITransportBridgePrivate::pageProxyPointer(self.webView);
    ptrdiff_t preferredCachedOffset = _controllerOffset;
    if (preferredCachedOffset == WITransportBridgePrivate::invalidControllerOffset)
        preferredCachedOffset = WITransportBridgePrivate::cachedControllerOffset.load();

    auto resolution = WITransportBridgePrivate::resolveControllerInPageProxy(page, preferredCachedOffset);
    void *controller = resolution.controller;
    void *backendDispatcher = resolution.backendDispatcher;

    _controller = controller;
    _backendDispatcher = backendDispatcher;
    _controllerOffset = resolution.stats.resolvedOffset;
    if (_controllerOffset != WITransportBridgePrivate::invalidControllerOffset)
        WITransportBridgePrivate::cachedControllerOffset.store(_controllerOffset);

#if TARGET_OS_OSX
    BOOL requiresInspectorConnection = NO;
#else
    BOOL requiresInspectorConnection = YES;
#endif

    if ((requiresInspectorConnection && !_inspector) || !_controller || !_backendDispatcher) {
        NSString *diagnostics = WITransportBridgePrivate::controllerResolutionDiagnosticsString(resolution.stats);
        NSLog(@"[WebInspectorTransport] controller resolution failed %@", diagnostics);
        NSError *transportError = WITransportBridgePrivate::selectorFailureError(
            _inspector,
            page,
            controller,
            backendDispatcher,
            resolution.stats
        );
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
#endif

    _frontendChannel = std::make_unique<WITransportFrontendChannel>(self, resolvedFunctions.stringImplToNSStringAddress);
    connectFrontend(_controller, *_frontendChannel, false, false);
    _frontendAttached = YES;
    return YES;
}

- (BOOL)sendRootJSONString:(NSString *)message error:(NSError * _Nullable __autoreleasing *)error
{
    if (!WITransportBridgePrivate::resolvedFunctionsAreComplete(_resolvedFunctions)) {
        [self invalidateAttachmentState];
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeUnsupported,
                @"Required runtime functions were unavailable."
            );
        }
        return NO;
    }
    if (!_backendDispatcher) {
        [self invalidateAttachmentState];
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeNotAttached,
                @"The root BackendDispatcher is unavailable."
            );
        }
        return NO;
    }
    if (![self attachedControllerIsStillValid]) {
        NSString *failureMessage = @"The root BackendDispatcher is unavailable.";
        [self invalidateAttachmentState];
        [self reportFatalFailure:failureMessage];
        if (error) {
            *error = WITransportBridgePrivate::makeError(
                WITransportBridgePrivate::ErrorCodeNotAttached,
                failureMessage
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

    WITransportInspectorABI::ConstructedString payloadString(
        message,
        _resolvedFunctions.stringFromUTF8Address,
        _resolvedFunctions.destroyStringImplAddress
    );
    WITransportInspectorABI::dispatchToBackendDispatcher(
        _backendDispatcher,
        payloadString.get(),
        _resolvedFunctions.backendDispatcherDispatchAddress
    );
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
    BOOL canDisconnectFrontend = NO;
    if (_frontendAttached && _frontendChannel && _controller && _disconnectFrontend) {
        canDisconnectFrontend = [self attachedControllerIsStillValid];
    }

    if (canDisconnectFrontend)
        _disconnectFrontend(_controller, *_frontendChannel);

    [self invalidateAttachmentState];
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

WITransportControllerDiscoveryTestResult WITransportFindInspectorControllerForTesting(
    const void *pageProxy,
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset
)
{
    size_t scanByteCount = pageAllocationSize ? pageAllocationSize : WITransportBridgePrivate::fallbackControllerScanBytes;
    bool usedFallbackRange = pageAllocationSize == 0;
    auto resolution = WITransportBridgePrivate::resolveControllerInPageProxy(
        const_cast<void *>(pageProxy),
        scanByteCount,
        usedFallbackRange,
        cachedOffset >= 0 ? cachedOffset : WITransportBridgePrivate::invalidControllerOffset
    );

    return {
        .found = resolution.stats.resolvedOffset != WITransportBridgePrivate::invalidControllerOffset,
        .usedFallbackRange = resolution.stats.usedFallbackRange,
        .resolvedOffset = resolution.stats.resolvedOffset,
        .attemptedOffsetCount = resolution.stats.attemptedOffsetCount,
        .validCandidateCount = resolution.stats.validCandidateCount,
        .scannedByteCount = resolution.stats.scannedByteCount,
    };
}

WITransportControllerDiscoveryTestResult WITransportRunControllerDiscoveryScenarioForTesting(
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset,
    NSInteger primaryControllerOffset,
    NSInteger secondaryControllerOffset
)
{
    size_t scanByteCount = pageAllocationSize ? pageAllocationSize : WITransportBridgePrivate::fallbackControllerScanBytes;
    std::vector<void *> allocations;

    void *pageBuffer = WITransportBridgePrivate::allocateZeroedBlock(scanByteCount, allocations);
    if (!pageBuffer) {
        return {
            .found = NO,
            .usedFallbackRange = NO,
            .resolvedOffset = WITransportBridgePrivate::invalidControllerOffset,
            .attemptedOffsetCount = 0,
            .validCandidateCount = 0,
            .scannedByteCount = 0,
        };
    }

    WITransportBridgePrivate::installSyntheticControllerAtOffset(pageBuffer, scanByteCount, primaryControllerOffset, allocations);
    WITransportBridgePrivate::installSyntheticControllerAtOffset(pageBuffer, scanByteCount, secondaryControllerOffset, allocations);

    auto resolution = WITransportBridgePrivate::resolveControllerInPageProxy(
        pageBuffer,
        scanByteCount,
        pageAllocationSize == 0,
        cachedOffset >= 0 ? cachedOffset : WITransportBridgePrivate::invalidControllerOffset
    );

    WITransportBridgePrivate::freeAllocatedBlocks(allocations);

    return {
        .found = resolution.stats.resolvedOffset != WITransportBridgePrivate::invalidControllerOffset,
        .usedFallbackRange = resolution.stats.usedFallbackRange,
        .resolvedOffset = resolution.stats.resolvedOffset,
        .attemptedOffsetCount = resolution.stats.attemptedOffsetCount,
        .validCandidateCount = resolution.stats.validCandidateCount,
        .scannedByteCount = resolution.stats.scannedByteCount,
    };
}

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

- (BOOL)attachWithResolvedFunctions:(WITransportResolvedFunctions)resolvedFunctions
                              error:(NSError * _Nullable __autoreleasing *)error
{
    (void)resolvedFunctions;
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

WITransportControllerDiscoveryTestResult WITransportFindInspectorControllerForTesting(
    const void *pageProxy,
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset
)
{
    (void)pageProxy;
    (void)pageAllocationSize;
    (void)cachedOffset;
    return {
        .found = NO,
        .usedFallbackRange = NO,
        .resolvedOffset = -1,
        .attemptedOffsetCount = 0,
        .validCandidateCount = 0,
        .scannedByteCount = 0,
    };
}

WITransportControllerDiscoveryTestResult WITransportRunControllerDiscoveryScenarioForTesting(
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset,
    NSInteger primaryControllerOffset,
    NSInteger secondaryControllerOffset
)
{
    (void)pageAllocationSize;
    (void)cachedOffset;
    (void)primaryControllerOffset;
    (void)secondaryControllerOffset;
    return {
        .found = NO,
        .usedFallbackRange = NO,
        .resolvedOffset = -1,
        .attemptedOffsetCount = 0,
        .validCandidateCount = 0,
        .scannedByteCount = 0,
    };
}

#endif
