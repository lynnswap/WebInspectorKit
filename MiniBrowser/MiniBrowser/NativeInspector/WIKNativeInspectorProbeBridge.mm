#import "WIKNativeInspectorProbeBridge.h"
#import "WIKInspectorABI.h"
#import <WebKit/WebKit.h>
#import "MiniBrowser-Swift.h"

#import <TargetConditionals.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <algorithm>
#import <atomic>
#import <objc/message.h>
#import <objc/runtime.h>
#import <memory>
#import <string.h>
#import <vector>

#if TARGET_OS_IPHONE && DEBUG
namespace WIKNativeInspectorProbe {

using ConnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&, bool, bool);
using DisconnectFrontendFn = void (*)(void *, Inspector::FrontendChannel&);

static constexpr ptrdiff_t invalidControllerOffset = -1;
static constexpr ptrdiff_t webPageInspectorControllerOffset = 0x4C0;
static constexpr size_t frontendRouterStorageIndex = 0;
static constexpr size_t backendDispatcherStorageIndex = 1;
static constexpr ptrdiff_t preferredControllerSearchRadius = 0x100;
static constexpr size_t fallbackControllerScanBytes = 0x1000;
static std::atomic<ptrdiff_t> cachedControllerOffset { invalidControllerOffset };
static constexpr NSUInteger bodyPreviewLimit = 4096;
static constexpr NSTimeInterval timeoutInterval = 15.0;

static NSString *const runningStatus = @"running";
static NSString *const succeededStatus = @"succeeded";
static NSString *const failedStatus = @"failed";

static NSString *const selectorStage = @"selector";
static NSString *const symbolStage = @"symbol";
static NSString *const attachStage = @"attach";
static NSString *const eventStage = @"event";
static NSString *const bodyFetchStage = @"body fetch";

extern void backendDispatcherDispatch(void *, const WTF::String&) asm("__ZN9Inspector17BackendDispatcher8dispatchERKN3WTF6StringE");

static NSString *stringValue(id value)
{
    if ([value isKindOfClass:NSString.class])
        return value;
    if ([value respondsToSelector:@selector(stringValue)])
        return [value stringValue];
    return nil;
}

static NSDictionary *dictionaryValue(id value)
{
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
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

static NSString *pointerString(const void *pointer)
{
    return pointer ? [NSString stringWithFormat:@"0x%llx", static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(pointer))] : @"nil";
}

static NSString *offsetString(ptrdiff_t offset)
{
    if (offset == NSNotFound)
        return @"NSNotFound";
    if (offset == invalidControllerOffset)
        return @"invalid";
    return [NSString stringWithFormat:@"0x%tx", offset];
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

static WIKWebKitLocalSymbolResolution *resolvedAttachSymbols()
{
    static WIKWebKitLocalSymbolResolution *symbols = [WIKWebKitLocalSymbolResolver resolveCurrentWebKitAttachSymbols];
    return symbols;
}

static ConnectFrontendFn connectFrontend()
{
    WIKWebKitLocalSymbolResolution *symbols = resolvedAttachSymbols();
    return reinterpret_cast<ConnectFrontendFn>(static_cast<uintptr_t>(symbols.connectFrontendAddress));
}

static DisconnectFrontendFn disconnectFrontend()
{
    WIKWebKitLocalSymbolResolution *symbols = resolvedAttachSymbols();
    return reinterpret_cast<DisconnectFrontendFn>(static_cast<uintptr_t>(symbols.disconnectFrontendAddress));
}

static NSString *attachSymbolFailureReason()
{
    WIKWebKitLocalSymbolResolution *symbols = resolvedAttachSymbols();
    return symbols.failureReason;
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

static void *pageProxyPointer(WKWebView *webView, ptrdiff_t *offsetOut = nullptr)
{
    ptrdiff_t offset = ivarOffset(WKWebView.class, "_page");
    if (offsetOut)
        *offsetOut = offset;
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
    if (offset < 0)
        return NO;

    auto *slot = reinterpret_cast<uint8_t *>(pageProxy) + offset;
    void *controller = nullptr;
    if (!safeReadPointer(slot, &controller) || !controller)
        return NO;
    if (!pointerIsWritableMapped(controller))
        return NO;

    void *frontendRouter = nullptr;
    if (!frontendRouterPointer(controller, &frontendRouter) || !frontendRouter)
        return NO;
    if (!pointerIsWritableMapped(frontendRouter))
        return NO;

    void *backendDispatcher = nullptr;
    if (!backendDispatcherPointer(controller, &backendDispatcher) || !backendDispatcher)
        return NO;
    if (!pointerIsWritableMapped(backendDispatcher))
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

static NSString *selectorFailureMessage(id inspectorObject, BOOL pageSourcesDisagree, void *pageProxy, void *controller, void *backendDispatcher)
{
    if (!inspectorObject)
        return @"WKWebView._inspector was unavailable.";
    if (pageSourcesDisagree)
        return @"WKWebView._page getter and ivar disagreed on the WebPageProxy address.";
    if (!pageProxy)
        return @"Unable to resolve WebPageProxy from WKWebView.";
    if (!controller)
        return @"Unable to resolve a unique WebPageInspectorController from WebPageProxy.";
    if (!backendDispatcher)
        return @"Unable to resolve Inspector::BackendDispatcher from WebPageInspectorController.";
    return @"Required private selectors or inspector controller state were unavailable.";
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

static NSString *truncatePreview(NSString *body)
{
    if (!body.length)
        return body;
    if (body.length <= bodyPreviewLimit)
        return body;
    return [[body substringToIndex:bodyPreviewLimit] stringByAppendingString:@"\n…"];
}

} // namespace WIKNativeInspectorProbe

@interface WIKNativeInspectorProbeSession ()

@property (nonatomic, weak, readonly) WKWebView *webView;
@property (nonatomic, copy) WIKNativeInspectorProbeEventHandler eventHandler;
@property (nonatomic, copy) NSString *targetURLString;
@property (nonatomic, copy, nullable) NSString *pageTargetIdentifier;
@property (nonatomic, copy, nullable) NSString *matchedRequestIdentifier;
@property (nonatomic, copy, nullable) NSString *matchedURLString;
@property (nonatomic, assign) BOOL networkEnableSent;
@property (nonatomic, assign) BOOL reloadStarted;
@property (nonatomic, assign) BOOL bodyRequestSent;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong, nullable) dispatch_source_t timeoutSource;
- (void)handleFrontendMessageString:(NSString *)messageString;
- (void)handleTargetMessageString:(NSString *)messageString targetIdentifier:(NSString *)targetIdentifier;
- (nullable NSString *)commandJSONStringWithIdentifier:(NSNumber *)identifier method:(NSString *)method params:(nullable NSDictionary *)params stage:(NSString *)stage failureMessage:(NSString *)failureMessage;
- (void)sendRootCommandWithIdentifier:(NSNumber *)identifier method:(NSString *)method params:(nullable NSDictionary *)params stage:(NSString *)stage failureMessage:(NSString *)failureMessage;
- (void)sendTargetCommandWithOuterIdentifier:(NSNumber *)outerIdentifier innerIdentifier:(NSNumber *)innerIdentifier method:(NSString *)method params:(nullable NSDictionary *)params stage:(NSString *)stage failureMessage:(NSString *)failureMessage;
@property (nonatomic, copy, nullable) NSString *lastTargetMessageString;

@end

class WIKFrontendChannel final : public Inspector::FrontendChannel {
public:
    explicit WIKFrontendChannel(WIKNativeInspectorProbeSession *owner)
        : m_owner(owner)
    {
    }

    ConnectionType connectionType() const override
    {
        return ConnectionType::Local;
    }

    void sendMessageToFrontend(const WTF::String& message) override
    {
        NSString *messageString = WIKInspectorABI::copyNSString(message);
        __weak WIKNativeInspectorProbeSession *owner = m_owner;
        dispatch_async(dispatch_get_main_queue(), ^{
            [owner handleFrontendMessageString:messageString];
        });
    }

private:
    __weak WIKNativeInspectorProbeSession *m_owner;
};

@interface WIKNativeInspectorProbeRecord ()

@property (nonatomic, readwrite, copy) NSString *status;
@property (nonatomic, readwrite, copy) NSString *stage;
@property (nonatomic, readwrite, copy) NSString *message;
@property (nonatomic, readwrite, copy, nullable) NSString *URLString;
@property (nonatomic, readwrite, copy, nullable) NSString *requestIdentifier;
@property (nonatomic, readwrite, copy, nullable) NSString *bodyPreview;
@property (nonatomic, readwrite) BOOL base64Encoded;
@property (nonatomic, readwrite, copy, nullable) NSString *rawBackendError;
@property (nonatomic, readwrite, copy, nullable) NSString *rawMessage;

@end

@implementation WIKNativeInspectorProbeRecord

- (instancetype)initWithStatus:(NSString *)status
                         stage:(NSString *)stage
                       message:(NSString *)message
                     URLString:(nullable NSString *)URLString
             requestIdentifier:(nullable NSString *)requestIdentifier
                   bodyPreview:(nullable NSString *)bodyPreview
                 base64Encoded:(BOOL)base64Encoded
               rawBackendError:(nullable NSString *)rawBackendError
                    rawMessage:(nullable NSString *)rawMessage
{
    self = [super init];
    if (!self)
        return nil;

    _status = [status copy];
    _stage = [stage copy];
    _message = [message copy];
    _URLString = [URLString copy];
    _requestIdentifier = [requestIdentifier copy];
    _bodyPreview = [bodyPreview copy];
    _base64Encoded = base64Encoded;
    _rawBackendError = [rawBackendError copy];
    _rawMessage = [rawMessage copy];
    return self;
}

@end

@implementation WIKNativeInspectorProbeSession {
    __weak WKWebView *_webView;
    id _inspector;
    void *_controller;
    void *_backendDispatcher;
    std::unique_ptr<WIKFrontendChannel> _frontendChannel;
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
    [self cancel];
}

- (void)startForURL:(NSURL *)url eventHandler:(WIKNativeInspectorProbeEventHandler)eventHandler
{
    [self cancel];

    self.eventHandler = eventHandler;
    self.targetURLString = url.absoluteString ?: @"";
    self.pageTargetIdentifier = nil;
    self.matchedRequestIdentifier = nil;
    self.matchedURLString = nil;
    self.networkEnableSent = NO;
    self.reloadStarted = NO;
    self.bodyRequestSent = NO;
    self.finished = NO;

    [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                         stage:WIKNativeInspectorProbe::selectorStage
                       message:@"Resolving private inspector selectors."
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:nil
                    rawMessage:nil];

    if (!self.webView) {
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:WIKNativeInspectorProbe::selectorStage
                       message:@"WKWebView was released before the probe started."
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:nil
                    rawMessage:nil];
        return;
    }

    _inspector = WIKNativeInspectorProbe::invokeObjectGetter(self.webView, @"_inspector");
    ptrdiff_t webViewPageOffset = NSNotFound;
    BOOL pageGetterSkipped = YES;
    void *pageFromGetter = nullptr;
    void *pageFromIvar = WIKNativeInspectorProbe::pageProxyPointer(self.webView, &webViewPageOffset);
    BOOL pageSourcesDisagree = pageFromGetter && pageFromIvar && pageFromGetter != pageFromIvar;
    void *page = pageSourcesDisagree ? nullptr : (pageFromGetter ?: pageFromIvar);

    auto controllerResolution = WIKNativeInspectorProbe::resolveControllerInPageProxy(
        page,
        WIKNativeInspectorProbe::cachedControllerOffset.load(std::memory_order_relaxed)
    );
    void *controller = controllerResolution.controller;
    void *backendDispatcher = controllerResolution.backendDispatcher;
    ptrdiff_t resolvedControllerOffset = controllerResolution.stats.resolvedOffset;
    if (resolvedControllerOffset != WIKNativeInspectorProbe::invalidControllerOffset)
        WIKNativeInspectorProbe::cachedControllerOffset.store(resolvedControllerOffset, std::memory_order_relaxed);

    NSString *selectorDiagnostics = [@[
        [NSString stringWithFormat:@"inspectorObject=%@", _inspector ? NSStringFromClass([_inspector class]) : @"nil"],
        [NSString stringWithFormat:@"pageFromGetter=%@", WIKNativeInspectorProbe::pointerString(pageFromGetter)],
        [NSString stringWithFormat:@"pageFromIvar=%@", WIKNativeInspectorProbe::pointerString(pageFromIvar)],
        [NSString stringWithFormat:@"WKWebView._page offset=%@", WIKNativeInspectorProbe::offsetString(webViewPageOffset)],
        [NSString stringWithFormat:@"pageGetterSkipped=%@", pageGetterSkipped ? @"yes" : @"no"],
        [NSString stringWithFormat:@"pageSourcesDisagree=%@", pageSourcesDisagree ? @"yes" : @"no"],
        [NSString stringWithFormat:@"page=%@", WIKNativeInspectorProbe::pointerString(page)],
        [NSString stringWithFormat:@"controller=%@", WIKNativeInspectorProbe::pointerString(controller)],
        [NSString stringWithFormat:@"backendDispatcher=%@", WIKNativeInspectorProbe::pointerString(backendDispatcher)],
        [NSString stringWithFormat:@"resolvedControllerOffset=%@", WIKNativeInspectorProbe::offsetString(resolvedControllerOffset)],
        [NSString stringWithFormat:@"controllerResolution=%@", WIKNativeInspectorProbe::controllerResolutionDiagnosticsString(controllerResolution.stats)],
    ] componentsJoinedByString:@"\n"];

    _controller = controller;
    _backendDispatcher = backendDispatcher;

    if (!_inspector || !_controller || !_backendDispatcher) {
        NSString *message = WIKNativeInspectorProbe::selectorFailureMessage(_inspector, pageSourcesDisagree, page, controller, backendDispatcher);
        NSLog(@"[NativeInspectorProbe] selector failure\n%@", selectorDiagnostics);
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:WIKNativeInspectorProbe::selectorStage
                       message:message
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:message
                    rawMessage:selectorDiagnostics];
        return;
    }

    NSLog(@"[NativeInspectorProbe] selector resolved\n%@", selectorDiagnostics);

    NSLog(@"[NativeInspectorProbe] resolving attach symbols");
    auto *connect = WIKNativeInspectorProbe::connectFrontend();
    auto *disconnect = WIKNativeInspectorProbe::disconnectFrontend();
    if (!connect || !disconnect) {
        NSString *failureReason = WIKNativeInspectorProbe::attachSymbolFailureReason() ?: @"connect/disconnect symbol missing";
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:WIKNativeInspectorProbe::symbolStage
                       message:failureReason
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:failureReason
                    rawMessage:failureReason];
        return;
    }
    NSLog(@"[NativeInspectorProbe] attach symbols resolved connect=%p disconnect=%p", connect, disconnect);

    [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                         stage:WIKNativeInspectorProbe::symbolStage
                       message:@"Resolved private WebKit attach symbols."
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:nil
                    rawMessage:nil];

    NSLog(@"[NativeInspectorProbe] invoking _WKInspector.connect");
    if (!WIKNativeInspectorProbe::invokeVoid(_inspector, @"connect")) {
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:WIKNativeInspectorProbe::attachStage
                       message:@"_WKInspector.connect was unavailable."
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:nil
                    rawMessage:nil];
        return;
    }
    NSLog(@"[NativeInspectorProbe] _WKInspector.connect returned");

    _frontendChannel = std::make_unique<WIKFrontendChannel>(self);
    NSLog(@"[NativeInspectorProbe] invoking WebPageInspectorController::connectFrontend controller=%p", _controller);
    connect(_controller, *_frontendChannel, false, false);
    NSLog(@"[NativeInspectorProbe] WebPageInspectorController::connectFrontend returned");
    _frontendAttached = YES;

    [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                         stage:WIKNativeInspectorProbe::attachStage
                       message:@"Attached a native FrontendChannel and waiting for the page target."
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:nil
                    rawMessage:nil];

    [self scheduleTimeout];
}

- (void)cancel
{
    [self invalidateTimeout];

    if (_frontendAttached && _frontendChannel && _controller) {
        if (auto *disconnect = WIKNativeInspectorProbe::disconnectFrontend())
            disconnect(_controller, *_frontendChannel);
    }

    _frontendAttached = NO;
    _frontendChannel.reset();
    _inspector = nil;
    _controller = nullptr;
    _backendDispatcher = nullptr;
    self.pageTargetIdentifier = nil;
    self.lastTargetMessageString = nil;
    self.eventHandler = nil;
    self.finished = YES;
}

- (void)handleFrontendMessageString:(NSString *)messageString
{
    if (self.finished || !messageString.length)
        return;

    NSData *payloadData = [messageString dataUsingEncoding:NSUTF8StringEncoding];
    if (!payloadData)
        return;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:&error];
    NSDictionary *message = WIKNativeInspectorProbe::dictionaryValue(json);
    if (!message || error)
        return;

    NSString *messageID = WIKNativeInspectorProbe::stringValue(message[@"id"]);
    NSDictionary *messageError = WIKNativeInspectorProbe::dictionaryValue(message[@"error"]);
    NSString *method = WIKNativeInspectorProbe::stringValue(message[@"method"]);
    NSDictionary *params = WIKNativeInspectorProbe::dictionaryValue(message[@"params"]);

    if ([messageID isEqualToString:@"101"]) {
        if (messageError) {
            [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                             stage:WIKNativeInspectorProbe::eventStage
                           message:@"Target.sendMessageToTarget(Network.enable) returned a root inspector error."
                         URLString:self.targetURLString
                 requestIdentifier:nil
                       bodyPreview:nil
                     base64Encoded:NO
                   rawBackendError:WIKNativeInspectorProbe::stringValue(messageError[@"message"])
                        rawMessage:messageString];
        }
        return;
    }

    if ([messageID isEqualToString:@"102"]) {
        if (messageError) {
            [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                             stage:WIKNativeInspectorProbe::bodyFetchStage
                           message:@"Target.sendMessageToTarget(Network.getResponseBody) returned a root inspector error."
                         URLString:self.matchedURLString ?: self.targetURLString
                 requestIdentifier:self.matchedRequestIdentifier
                       bodyPreview:nil
                     base64Encoded:NO
                   rawBackendError:WIKNativeInspectorProbe::stringValue(messageError[@"message"])
                        rawMessage:messageString];
        }
        return;
    }

    if (!method.length)
        return;

    if ([method isEqualToString:@"Target.targetCreated"]) {
        NSDictionary *targetInfo = WIKNativeInspectorProbe::dictionaryValue(params[@"targetInfo"]);
        NSString *targetIdentifier = WIKNativeInspectorProbe::stringValue(targetInfo[@"targetId"]);
        NSString *targetType = WIKNativeInspectorProbe::stringValue(targetInfo[@"type"]);
        BOOL provisional = [targetInfo[@"isProvisional"] respondsToSelector:@selector(boolValue)] ? [targetInfo[@"isProvisional"] boolValue] : NO;
        if (![targetType isEqualToString:@"page"] || !targetIdentifier.length || provisional)
            return;

        self.pageTargetIdentifier = targetIdentifier;
        [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                             stage:WIKNativeInspectorProbe::eventStage
                           message:@"Observed the page target and forwarding Network.enable through Target.sendMessageToTarget."
                         URLString:self.targetURLString
                 requestIdentifier:nil
                       bodyPreview:nil
                     base64Encoded:NO
                   rawBackendError:nil
                        rawMessage:messageString];

        if (self.networkEnableSent)
            return;

        self.networkEnableSent = YES;
        [self sendTargetCommandWithOuterIdentifier:@101
                                   innerIdentifier:@1
                                            method:@"Network.enable"
                                            params:nil
                                             stage:WIKNativeInspectorProbe::eventStage
                                    failureMessage:@"Failed to forward Network.enable to the page target."];
        return;
    }

    if ([method isEqualToString:@"Target.didCommitProvisionalTarget"]) {
        NSString *oldTargetIdentifier = WIKNativeInspectorProbe::stringValue(params[@"oldTargetId"]);
        NSString *newTargetIdentifier = WIKNativeInspectorProbe::stringValue(params[@"newTargetId"]);
        if (self.pageTargetIdentifier.length
            && [oldTargetIdentifier isEqualToString:self.pageTargetIdentifier]
            && newTargetIdentifier.length) {
            self.pageTargetIdentifier = newTargetIdentifier;
            [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                                 stage:WIKNativeInspectorProbe::eventStage
                               message:@"Updated the tracked page target after provisional commit."
                             URLString:self.targetURLString
                     requestIdentifier:self.matchedRequestIdentifier
                           bodyPreview:nil
                         base64Encoded:NO
                       rawBackendError:nil
                            rawMessage:messageString];
        }
        return;
    }

    if ([method isEqualToString:@"Target.targetDestroyed"]) {
        NSString *targetIdentifier = WIKNativeInspectorProbe::stringValue(params[@"targetId"]);
        if (self.pageTargetIdentifier.length && [targetIdentifier isEqualToString:self.pageTargetIdentifier] && !self.matchedRequestIdentifier.length) {
            [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                             stage:WIKNativeInspectorProbe::eventStage
                           message:@"The tracked page target was destroyed before any main-document network event arrived."
                         URLString:self.targetURLString
                 requestIdentifier:nil
                       bodyPreview:nil
                     base64Encoded:NO
                   rawBackendError:nil
                        rawMessage:messageString];
        }
        return;
    }

    if ([method isEqualToString:@"Target.dispatchMessageFromTarget"]) {
        NSString *targetIdentifier = WIKNativeInspectorProbe::stringValue(params[@"targetId"]);
        NSString *targetMessageString = WIKNativeInspectorProbe::stringValue(params[@"message"]);
        if (!targetIdentifier.length || !targetMessageString.length)
            return;
        if (self.pageTargetIdentifier.length && ![targetIdentifier isEqualToString:self.pageTargetIdentifier])
            return;
        self.lastTargetMessageString = targetMessageString;
        [self handleTargetMessageString:targetMessageString targetIdentifier:targetIdentifier];
    }
}

- (void)handleTargetMessageString:(NSString *)messageString targetIdentifier:(NSString *)targetIdentifier
{
    if (self.finished || !messageString.length)
        return;

    NSData *payloadData = [messageString dataUsingEncoding:NSUTF8StringEncoding];
    if (!payloadData)
        return;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:&error];
    NSDictionary *message = WIKNativeInspectorProbe::dictionaryValue(json);
    if (!message || error)
        return;

    NSString *messageID = WIKNativeInspectorProbe::stringValue(message[@"id"]);
    NSDictionary *messageError = WIKNativeInspectorProbe::dictionaryValue(message[@"error"]);
    NSDictionary *result = WIKNativeInspectorProbe::dictionaryValue(message[@"result"]);
    NSString *method = WIKNativeInspectorProbe::stringValue(message[@"method"]);
    NSDictionary *params = WIKNativeInspectorProbe::dictionaryValue(message[@"params"]);

    if ([messageID isEqualToString:@"1"]) {
        if (messageError) {
            [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                             stage:WIKNativeInspectorProbe::eventStage
                           message:@"Network.enable returned an inspector error from the page target."
                         URLString:self.targetURLString
                 requestIdentifier:nil
                       bodyPreview:nil
                     base64Encoded:NO
                   rawBackendError:WIKNativeInspectorProbe::stringValue(messageError[@"message"])
                        rawMessage:messageString];
            return;
        }

        if (!self.reloadStarted) {
            self.reloadStarted = YES;
            [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                                 stage:WIKNativeInspectorProbe::eventStage
                               message:@"Network enabled on the page target; reloading https://example.com/ to observe the main document."
                             URLString:self.targetURLString
                     requestIdentifier:nil
                           bodyPreview:nil
                         base64Encoded:NO
                       rawBackendError:nil
                            rawMessage:messageString];
            [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:self.targetURLString]]];
        }
        return;
    }

    if ([messageID isEqualToString:@"2"]) {
        if (messageError) {
            [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                             stage:WIKNativeInspectorProbe::bodyFetchStage
                           message:@"Network.getResponseBody returned an inspector error from the page target."
                         URLString:self.matchedURLString ?: self.targetURLString
                 requestIdentifier:self.matchedRequestIdentifier
                       bodyPreview:nil
                     base64Encoded:NO
                   rawBackendError:WIKNativeInspectorProbe::stringValue(messageError[@"message"])
                        rawMessage:messageString];
            return;
        }

        NSString *body = WIKNativeInspectorProbe::stringValue(result[@"body"]) ?: @"";
        BOOL base64Encoded = [result[@"base64Encoded"] respondsToSelector:@selector(boolValue)] ? [result[@"base64Encoded"] boolValue] : NO;
        [self finishWithStatus:WIKNativeInspectorProbe::succeededStatus
                         stage:WIKNativeInspectorProbe::bodyFetchStage
                       message:@"Fetched the response body through native-only target messaging."
                     URLString:self.matchedURLString ?: self.targetURLString
             requestIdentifier:self.matchedRequestIdentifier
                   bodyPreview:WIKNativeInspectorProbe::truncatePreview(body)
                 base64Encoded:base64Encoded
               rawBackendError:nil
                    rawMessage:messageString];
        return;
    }

    if (!method.length)
        return;

    if ([method isEqualToString:@"Network.responseReceived"]) {
        NSString *requestIdentifier = WIKNativeInspectorProbe::stringValue(params[@"requestId"]);
        NSDictionary *response = WIKNativeInspectorProbe::dictionaryValue(params[@"response"]);
        NSString *URLString = WIKNativeInspectorProbe::stringValue(response[@"url"]);
        NSString *resourceType = WIKNativeInspectorProbe::stringValue(params[@"type"]);

        if (!self.matchedRequestIdentifier
            && requestIdentifier.length
            && URLString.length
            && [URLString isEqualToString:self.targetURLString]
            && (!resourceType.length || [resourceType isEqualToString:@"Document"])) {
            self.matchedRequestIdentifier = requestIdentifier;
            self.matchedURLString = URLString;
            [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                                 stage:WIKNativeInspectorProbe::eventStage
                               message:@"Observed the main document response."
                             URLString:URLString
                     requestIdentifier:requestIdentifier
                           bodyPreview:nil
                         base64Encoded:NO
                       rawBackendError:nil
                            rawMessage:messageString];
        }
        return;
    }

    if ([method isEqualToString:@"Network.loadingFailed"]) {
        NSString *requestIdentifier = WIKNativeInspectorProbe::stringValue(params[@"requestId"]);
        if (self.matchedRequestIdentifier.length && [requestIdentifier isEqualToString:self.matchedRequestIdentifier]) {
            [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                             stage:WIKNativeInspectorProbe::eventStage
                           message:@"The target navigation failed before the body became available."
                         URLString:self.matchedURLString ?: self.targetURLString
                 requestIdentifier:requestIdentifier
                       bodyPreview:nil
                     base64Encoded:NO
                   rawBackendError:WIKNativeInspectorProbe::stringValue(params[@"errorText"])
                        rawMessage:messageString];
        }
        return;
    }

    if ([method isEqualToString:@"Network.loadingFinished"]) {
        NSString *requestIdentifier = WIKNativeInspectorProbe::stringValue(params[@"requestId"]);
        if (self.matchedRequestIdentifier.length
            && [requestIdentifier isEqualToString:self.matchedRequestIdentifier]
            && !self.bodyRequestSent) {
            self.bodyRequestSent = YES;
            [self emitRecordWithStatus:WIKNativeInspectorProbe::runningStatus
                                 stage:WIKNativeInspectorProbe::bodyFetchStage
                               message:@"Target load finished; requesting Network.getResponseBody."
                            URLString:self.matchedURLString ?: self.targetURLString
                     requestIdentifier:requestIdentifier
                           bodyPreview:nil
                         base64Encoded:NO
                       rawBackendError:nil
                            rawMessage:messageString];
            [self sendTargetCommandWithOuterIdentifier:@102
                                       innerIdentifier:@2
                                                method:@"Network.getResponseBody"
                                                params:@{ @"requestId": requestIdentifier }
                                                 stage:WIKNativeInspectorProbe::bodyFetchStage
                                        failureMessage:@"Failed to forward Network.getResponseBody to the page target."];
        }
    }
}

- (nullable NSString *)commandJSONStringWithIdentifier:(NSNumber *)identifier
                                                method:(NSString *)method
                                                params:(nullable NSDictionary *)params
                                                 stage:(NSString *)stage
                                        failureMessage:(NSString *)failureMessage
{
    NSError *error = nil;
    NSMutableDictionary *payload = [@{
        @"id": identifier,
        @"method": method,
    } mutableCopy];
    if (params.count)
        payload[@"params"] = params;

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!jsonData || error) {
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:stage
                       message:failureMessage
                     URLString:self.matchedURLString ?: self.targetURLString
             requestIdentifier:self.matchedRequestIdentifier
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:error.localizedDescription
                    rawMessage:nil];
        return nil;
    }

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (!jsonString.length) {
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:stage
                       message:failureMessage
                     URLString:self.matchedURLString ?: self.targetURLString
             requestIdentifier:self.matchedRequestIdentifier
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:@"The inspector command payload could not be converted to UTF-8."
                    rawMessage:nil];
        return nil;
    }

    return jsonString;
}

- (void)sendRootCommandWithIdentifier:(NSNumber *)identifier
                               method:(NSString *)method
                               params:(nullable NSDictionary *)params
                                stage:(NSString *)stage
                       failureMessage:(NSString *)failureMessage
{
    NSString *jsonString = [self commandJSONStringWithIdentifier:identifier
                                                          method:method
                                                          params:params
                                                           stage:stage
                                                  failureMessage:failureMessage];
    if (!jsonString.length)
        return;
    if (!_backendDispatcher) {
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:stage
                       message:failureMessage
                     URLString:self.matchedURLString ?: self.targetURLString
             requestIdentifier:self.matchedRequestIdentifier
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:@"Missing root BackendDispatcher."
                    rawMessage:nil];
        return;
    }

    WIKInspectorABI::ConstructedString payloadString(jsonString);
    WIKNativeInspectorProbe::backendDispatcherDispatch(_backendDispatcher, payloadString.get());
}

- (void)sendTargetCommandWithOuterIdentifier:(NSNumber *)outerIdentifier
                             innerIdentifier:(NSNumber *)innerIdentifier
                                      method:(NSString *)method
                                      params:(nullable NSDictionary *)params
                                       stage:(NSString *)stage
                              failureMessage:(NSString *)failureMessage
{
    if (!self.pageTargetIdentifier.length) {
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:stage
                       message:failureMessage
                     URLString:self.matchedURLString ?: self.targetURLString
             requestIdentifier:self.matchedRequestIdentifier
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:@"Missing page target identifier."
                    rawMessage:nil];
        return;
    }

    NSString *innerMessage = [self commandJSONStringWithIdentifier:innerIdentifier
                                                            method:method
                                                            params:params
                                                             stage:stage
                                                    failureMessage:failureMessage];
    if (!innerMessage.length)
        return;

    [self sendRootCommandWithIdentifier:outerIdentifier
                                 method:@"Target.sendMessageToTarget"
                                 params:@{
                                     @"targetId": self.pageTargetIdentifier,
                                     @"message": innerMessage,
                                 }
                                  stage:stage
                         failureMessage:failureMessage];
}

- (void)scheduleTimeout
{
    [self invalidateTimeout];

    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(
        source,
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(WIKNativeInspectorProbe::timeoutInterval * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER,
        static_cast<uint64_t>(0.1 * NSEC_PER_SEC)
    );

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.finished)
            return;

        NSString *message = nil;
        NSString *errorText = nil;
        if (self.matchedRequestIdentifier.length) {
            message = @"Timed out while waiting for Network.getResponseBody.";
            errorText = @"Timed out waiting for Network.getResponseBody.";
        } else if (self.pageTargetIdentifier.length) {
            message = @"Timed out while waiting for the main document network event.";
            errorText = @"Timed out waiting for network events from the page target.";
        } else {
            message = @"Timed out while waiting for Target.targetCreated for the page.";
            errorText = @"Timed out waiting for a page target.";
        }
        NSString *stage = self.matchedRequestIdentifier.length
            ? WIKNativeInspectorProbe::bodyFetchStage
            : WIKNativeInspectorProbe::eventStage;
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:stage
                       message:message
                     URLString:self.matchedURLString ?: self.targetURLString
             requestIdentifier:self.matchedRequestIdentifier
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:errorText
                    rawMessage:self.lastTargetMessageString];
    });
    dispatch_resume(source);
    self.timeoutSource = source;
}

- (void)invalidateTimeout
{
    if (!self.timeoutSource)
        return;

    dispatch_source_cancel(self.timeoutSource);
    self.timeoutSource = nil;
}

- (void)emitRecordWithStatus:(NSString *)status
                       stage:(NSString *)stage
                     message:(NSString *)message
                   URLString:(nullable NSString *)URLString
           requestIdentifier:(nullable NSString *)requestIdentifier
                 bodyPreview:(nullable NSString *)bodyPreview
               base64Encoded:(BOOL)base64Encoded
             rawBackendError:(nullable NSString *)rawBackendError
                  rawMessage:(nullable NSString *)rawMessage
{
    NSLog(@"[NativeInspectorProbe] record status=%@ stage=%@ message=%@ url=%@ requestId=%@ backendError=%@",
        status,
        stage,
        message,
        URLString ?: @"n/a",
        requestIdentifier ?: @"n/a",
        rawBackendError ?: @"n/a");

    if (!self.eventHandler)
        return;

    self.eventHandler([[WIKNativeInspectorProbeRecord alloc] initWithStatus:status
                                                                      stage:stage
                                                                    message:message
                                                                  URLString:URLString
                                                          requestIdentifier:requestIdentifier
                                                                bodyPreview:bodyPreview
                                                              base64Encoded:base64Encoded
                                                            rawBackendError:rawBackendError
                                                                 rawMessage:rawMessage]);
}

- (void)finishWithStatus:(NSString *)status
                   stage:(NSString *)stage
                 message:(NSString *)message
               URLString:(nullable NSString *)URLString
       requestIdentifier:(nullable NSString *)requestIdentifier
             bodyPreview:(nullable NSString *)bodyPreview
           base64Encoded:(BOOL)base64Encoded
         rawBackendError:(nullable NSString *)rawBackendError
              rawMessage:(nullable NSString *)rawMessage
{
    if (self.finished)
        return;

    NSLog(@"[NativeInspectorProbe] finish status=%@ stage=%@ message=%@ url=%@ requestId=%@ backendError=%@",
        status,
        stage,
        message,
        URLString ?: @"n/a",
        requestIdentifier ?: @"n/a",
        rawBackendError ?: @"n/a");

    self.finished = YES;
    [self invalidateTimeout];
    [self emitRecordWithStatus:status
                         stage:stage
                       message:message
                     URLString:URLString
             requestIdentifier:requestIdentifier
                   bodyPreview:bodyPreview
                 base64Encoded:base64Encoded
               rawBackendError:rawBackendError
                    rawMessage:rawMessage];

    WIKNativeInspectorProbeEventHandler handler = self.eventHandler;
    [self cancel];
    self.eventHandler = handler;
    self.eventHandler = nil;
}

@end

WIKNativeInspectorControllerDiscoveryTestResult WIKNativeInspectorFindInspectorControllerForTesting(
    const void *pageProxy,
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset
)
{
    size_t scanByteCount = pageAllocationSize ? pageAllocationSize : WIKNativeInspectorProbe::fallbackControllerScanBytes;
    bool usedFallbackRange = pageAllocationSize == 0;
    auto resolution = WIKNativeInspectorProbe::resolveControllerInPageProxy(
        const_cast<void *>(pageProxy),
        scanByteCount,
        usedFallbackRange,
        cachedOffset >= 0 ? cachedOffset : WIKNativeInspectorProbe::invalidControllerOffset
    );

    return {
        .found = resolution.stats.resolvedOffset != WIKNativeInspectorProbe::invalidControllerOffset,
        .usedFallbackRange = resolution.stats.usedFallbackRange,
        .resolvedOffset = resolution.stats.resolvedOffset,
        .attemptedOffsetCount = resolution.stats.attemptedOffsetCount,
        .validCandidateCount = resolution.stats.validCandidateCount,
        .scannedByteCount = resolution.stats.scannedByteCount,
    };
}

WIKNativeInspectorControllerDiscoveryTestResult WIKNativeInspectorRunControllerDiscoveryScenarioForTesting(
    NSUInteger pageAllocationSize,
    NSInteger cachedOffset,
    NSInteger primaryControllerOffset,
    NSInteger secondaryControllerOffset
)
{
    size_t scanByteCount = pageAllocationSize ? pageAllocationSize : WIKNativeInspectorProbe::fallbackControllerScanBytes;
    std::vector<void *> allocations;

    void *pageBuffer = WIKNativeInspectorProbe::allocateZeroedBlock(scanByteCount, allocations);
    if (!pageBuffer) {
        return {
            .found = NO,
            .usedFallbackRange = NO,
            .resolvedOffset = WIKNativeInspectorProbe::invalidControllerOffset,
            .attemptedOffsetCount = 0,
            .validCandidateCount = 0,
            .scannedByteCount = 0,
        };
    }

    WIKNativeInspectorProbe::installSyntheticControllerAtOffset(pageBuffer, scanByteCount, primaryControllerOffset, allocations);
    WIKNativeInspectorProbe::installSyntheticControllerAtOffset(pageBuffer, scanByteCount, secondaryControllerOffset, allocations);

    auto resolution = WIKNativeInspectorProbe::resolveControllerInPageProxy(
        pageBuffer,
        scanByteCount,
        pageAllocationSize == 0,
        cachedOffset >= 0 ? cachedOffset : WIKNativeInspectorProbe::invalidControllerOffset
    );

    WIKNativeInspectorProbe::freeAllocatedBlocks(allocations);

    return {
        .found = resolution.stats.resolvedOffset != WIKNativeInspectorProbe::invalidControllerOffset,
        .usedFallbackRange = resolution.stats.usedFallbackRange,
        .resolvedOffset = resolution.stats.resolvedOffset,
        .attemptedOffsetCount = resolution.stats.attemptedOffsetCount,
        .validCandidateCount = resolution.stats.validCandidateCount,
        .scannedByteCount = resolution.stats.scannedByteCount,
    };
}

#else

@interface WIKNativeInspectorProbeRecord ()

@property (nonatomic, readwrite, copy) NSString *status;
@property (nonatomic, readwrite, copy) NSString *stage;
@property (nonatomic, readwrite, copy) NSString *message;
@property (nonatomic, readwrite, copy, nullable) NSString *URLString;
@property (nonatomic, readwrite, copy, nullable) NSString *requestIdentifier;
@property (nonatomic, readwrite, copy, nullable) NSString *bodyPreview;
@property (nonatomic, readwrite) BOOL base64Encoded;
@property (nonatomic, readwrite, copy, nullable) NSString *rawBackendError;
@property (nonatomic, readwrite, copy, nullable) NSString *rawMessage;

@end

@implementation WIKNativeInspectorProbeRecord

- (instancetype)initWithStatus:(NSString *)status
                         stage:(NSString *)stage
                       message:(NSString *)message
                     URLString:(nullable NSString *)URLString
             requestIdentifier:(nullable NSString *)requestIdentifier
                   bodyPreview:(nullable NSString *)bodyPreview
                 base64Encoded:(BOOL)base64Encoded
               rawBackendError:(nullable NSString *)rawBackendError
                    rawMessage:(nullable NSString *)rawMessage
{
    self = [super init];
    if (!self)
        return nil;

    _status = [status copy];
    _stage = [stage copy];
    _message = [message copy];
    _URLString = [URLString copy];
    _requestIdentifier = [requestIdentifier copy];
    _bodyPreview = [bodyPreview copy];
    _base64Encoded = base64Encoded;
    _rawBackendError = [rawBackendError copy];
    _rawMessage = [rawMessage copy];
    return self;
}

@end

@implementation WIKNativeInspectorProbeSession {
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

- (void)startForURL:(NSURL *)url eventHandler:(WIKNativeInspectorProbeEventHandler)eventHandler
{
    if (!eventHandler)
        return;

    eventHandler([[WIKNativeInspectorProbeRecord alloc] initWithStatus:@"failed"
                                                                 stage:@"selector"
                                                               message:@"Native inspector probing is only compiled for debug iOS builds."
                                                             URLString:url.absoluteString
                                                     requestIdentifier:nil
                                                           bodyPreview:nil
                                                         base64Encoded:NO
                                                       rawBackendError:nil
                                                            rawMessage:nil]);
}

- (void)cancel
{
}

@end

WIKNativeInspectorControllerDiscoveryTestResult WIKNativeInspectorFindInspectorControllerForTesting(
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

WIKNativeInspectorControllerDiscoveryTestResult WIKNativeInspectorRunControllerDiscoveryScenarioForTesting(
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
