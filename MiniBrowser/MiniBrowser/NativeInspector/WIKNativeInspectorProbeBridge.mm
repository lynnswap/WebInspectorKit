#import "WIKNativeInspectorProbeBridge.h"

#import <TargetConditionals.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <uuid/uuid.h>

#if TARGET_OS_IPHONE && DEBUG
#import "JavaScriptCore/inspector/InspectorFrontendChannel.h"

namespace WIKNativeInspectorProbe {

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

static const char *const webKitImageSuffix = "/System/Library/Frameworks/WebKit.framework/WebKit";
static const char *const connectFrontendSymbol = "__ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb";
static const char *const disconnectFrontendSymbol = "__ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE";

extern void backendDispatcherDispatch(void *, const WTF::String&) asm("__ZN9Inspector17BackendDispatcher8dispatchERKN3WTF6StringE");

#if !TARGET_OS_SIMULATOR
struct KnownWebKitLocalSymbols {
    uuid_t uuid;
    uintptr_t connectFrontendVMAddr;
    uintptr_t disconnectFrontendVMAddr;
};

static const KnownWebKitLocalSymbols knownDeviceWebKitLocalSymbols[] = {
    {
        { 0x6E, 0x97, 0x8F, 0xE3, 0x93, 0x4D, 0x3A, 0xE4, 0x96, 0xA2, 0xB4, 0x99, 0xFC, 0xA0, 0x86, 0x04 },
        0x19e4c4080,
        0x19e4c449c,
    },
    {
        { 0x75, 0x5C, 0xF1, 0x67, 0xFA, 0xD4, 0x3D, 0x28, 0x8A, 0xE6, 0x34, 0xEB, 0x86, 0xD8, 0x80, 0xCA },
        0x19e38ea70,
        0x19e38ee8c,
    },
};
#endif

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

static NSString *pointerString(const void *pointer)
{
    return pointer ? [NSString stringWithFormat:@"0x%llx", static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(pointer))] : @"nil";
}

static NSString *offsetString(ptrdiff_t offset)
{
    return offset == NSNotFound ? @"NSNotFound" : [NSString stringWithFormat:@"0x%tx", offset];
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

#if !TARGET_OS_SIMULATOR
static BOOL imageUUID(const mach_header_64 *header, uuid_t uuidOut)
{
    if (!header || !uuidOut || header->magic != MH_MAGIC_64)
        return NO;

    const load_command *command = reinterpret_cast<const load_command *>(header + 1);
    for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
        if (command->cmd == LC_UUID) {
            auto *uuidCommand = reinterpret_cast<const uuid_command *>(command);
            memcpy(uuidOut, uuidCommand->uuid, sizeof(uuid_t));
            return YES;
        }
        command = reinterpret_cast<const load_command *>(reinterpret_cast<const uint8_t *>(command) + command->cmdsize);
    }

    return NO;
}

static void *findKnownDeviceSymbol(const char *imageSuffix, const char *symbolName)
{
    NSLog(@"[NativeInspectorProbe] findKnownDeviceSymbol start symbol=%s", symbolName);
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const char *imageName = _dyld_get_image_name(imageIndex);
        if (!imageName || !strstr(imageName, imageSuffix))
            continue;

        NSLog(@"[NativeInspectorProbe] findKnownDeviceSymbol matched image=%s", imageName);

        auto *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(imageIndex));
        if (!header || header->magic != MH_MAGIC_64)
            return nullptr;

        uuid_t imageUUIDValue { 0 };
        if (!imageUUID(header, imageUUIDValue))
            return nullptr;

        char uuidBuffer[37] = { 0 };
        uuid_unparse_upper(imageUUIDValue, uuidBuffer);
        NSLog(@"[NativeInspectorProbe] findKnownDeviceSymbol image uuid=%s", uuidBuffer);

        for (const auto& knownSymbols : knownDeviceWebKitLocalSymbols) {
            if (uuid_compare(imageUUIDValue, knownSymbols.uuid))
                continue;

            uintptr_t vmaddr = 0;
            if (!strcmp(symbolName, connectFrontendSymbol))
                vmaddr = knownSymbols.connectFrontendVMAddr;
            else if (!strcmp(symbolName, disconnectFrontendSymbol))
                vmaddr = knownSymbols.disconnectFrontendVMAddr;

            if (!vmaddr)
                return nullptr;

            intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
            NSLog(@"[NativeInspectorProbe] findKnownDeviceSymbol resolved symbol=%s vmaddr=0x%llx slide=0x%llx", symbolName, static_cast<unsigned long long>(vmaddr), static_cast<unsigned long long>(slide));
            return reinterpret_cast<void *>(slide + vmaddr);
        }

        NSLog(@"[NativeInspectorProbe] findKnownDeviceSymbol uuid unsupported");
        return nullptr;
    }

    NSLog(@"[NativeInspectorProbe] findKnownDeviceSymbol image not found");
    return nullptr;
}
#endif

static void *findLocalSymbol(const char *imageSuffix, const char *symbolName)
{
#if TARGET_OS_SIMULATOR
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const char *imageName = _dyld_get_image_name(imageIndex);
        if (!imageName || !strstr(imageName, imageSuffix))
            continue;

        auto *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(imageIndex));
        if (!header || header->magic != MH_MAGIC_64)
            continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
        const load_command *command = reinterpret_cast<const load_command *>(header + 1);
        const segment_command_64 *linkEditSegment = nullptr;
        const symtab_command *symtab = nullptr;

        for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
            if (command->cmd == LC_SEGMENT_64) {
                auto *segment = reinterpret_cast<const segment_command_64 *>(command);
                if (!strcmp(segment->segname, SEG_LINKEDIT))
                    linkEditSegment = segment;
            } else if (command->cmd == LC_SYMTAB)
                symtab = reinterpret_cast<const symtab_command *>(command);

            command = reinterpret_cast<const load_command *>(reinterpret_cast<const uint8_t *>(command) + command->cmdsize);
        }

        if (!linkEditSegment || !symtab)
            continue;

        uintptr_t linkEditBase = static_cast<uintptr_t>(slide + linkEditSegment->vmaddr - linkEditSegment->fileoff);
        auto *symbolTable = reinterpret_cast<const nlist_64 *>(linkEditBase + symtab->symoff);
        auto *stringTable = reinterpret_cast<const char *>(linkEditBase + symtab->stroff);

        for (uint32_t symbolIndex = 0; symbolIndex < symtab->nsyms; symbolIndex++) {
            uint32_t stringOffset = symbolTable[symbolIndex].n_un.n_strx;
            if (!stringOffset)
                continue;

            const char *candidate = stringTable + stringOffset;
            if (strcmp(candidate, symbolName))
                continue;

            return reinterpret_cast<void *>(slide + symbolTable[symbolIndex].n_value);
        }
    }

    return nullptr;
#else
    if (void *knownAddress = findKnownDeviceSymbol(imageSuffix, symbolName)) {
        NSLog(@"[NativeInspectorProbe] findLocalSymbol using known device symbol=%s address=%p", symbolName, knownAddress);
        return knownAddress;
    }
    NSLog(@"[NativeInspectorProbe] findLocalSymbol known device symbol unavailable symbol=%s", symbolName);
    return nullptr;
#endif
}

static ConnectFrontendFn connectFrontend()
{
    static ConnectFrontendFn fn = reinterpret_cast<ConnectFrontendFn>(findLocalSymbol(webKitImageSuffix, connectFrontendSymbol));
    return fn;
}

static DisconnectFrontendFn disconnectFrontend()
{
    static DisconnectFrontendFn fn = reinterpret_cast<DisconnectFrontendFn>(findLocalSymbol(webKitImageSuffix, disconnectFrontendSymbol));
    return fn;
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

#if TARGET_OS_SIMULATOR
static void *invokePointerGetter(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nullptr;

    using Getter = void *(*)(id, SEL);
    return reinterpret_cast<Getter>(objc_msgSend)(target, selector);
}
#endif

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

static BOOL controllerCandidateAtOffset(void *pageProxy, ptrdiff_t offset, void **controllerOut, void **frontendRouterOut, void **backendDispatcherOut)
{
    if (!pageProxy)
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
    if (frontendRouterOut)
        *frontendRouterOut = frontendRouter;
    if (backendDispatcherOut)
        *backendDispatcherOut = backendDispatcher;
    return YES;
}

static NSString *selectorFailureMessage(id inspectorObject, BOOL pageSourcesDisagree, void *pageProxy, BOOL exactOffsetMatched, NSUInteger nearbyValidCandidateCount, void *controller, void *backendDispatcher)
{
    if (!inspectorObject)
        return @"WKWebView._inspector was unavailable.";
    if (pageSourcesDisagree)
        return @"WKWebView._page getter and ivar disagreed on the WebPageProxy address.";
    if (!pageProxy)
        return @"Unable to resolve WebPageProxy from WKWebView.";
    if (!exactOffsetMatched && nearbyValidCandidateCount)
        return @"Found nearby WebPageInspectorController candidates, but skipped attach because only the exact page + 0x4C0 slot is considered safe.";
    if (!controller)
        return @"Unable to resolve WebPageInspectorController from WebPageProxy near the expected offset.";
    if (!backendDispatcher)
        return @"Unable to resolve Inspector::BackendDispatcher from WebPageInspectorController.";
    return @"Required private selectors or inspector controller state were unavailable.";
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
        auto retained = message.createNSString();
        NSString *messageString = retained ? [retained.get() copy] : @"";
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
    BOOL pageGetterSkipped = NO;
    void *pageFromGetter = nullptr;
#if TARGET_OS_SIMULATOR
    pageFromGetter = WIKNativeInspectorProbe::invokePointerGetter(self.webView, @"_page");
#else
    pageGetterSkipped = YES;
#endif
    void *pageFromIvar = WIKNativeInspectorProbe::pageProxyPointer(self.webView, &webViewPageOffset);
    BOOL pageSourcesDisagree = pageFromGetter && pageFromIvar && pageFromGetter != pageFromIvar;
    void *page = pageSourcesDisagree ? nullptr : (pageFromGetter ?: pageFromIvar);

    void *controller = nullptr;
    void *frontendRouter = nullptr;
    void *backendDispatcher = nullptr;
    ptrdiff_t resolvedControllerOffset = NSNotFound;
    BOOL exactOffsetMatched = NO;
    NSUInteger validCandidateCount = 0;
    NSUInteger nearbyValidCandidateCount = 0;
    BOOL validatedNearbyOffsetAccepted = NO;
    NSMutableArray<NSString *> *candidateLines = [NSMutableArray array];
    for (ptrdiff_t candidateOffset : WIKNativeInspectorProbe::controllerCandidateOffsets) {
        void *candidateController = nullptr;
        void *candidateFrontendRouter = nullptr;
        void *candidateBackendDispatcher = nullptr;
        BOOL valid = WIKNativeInspectorProbe::controllerCandidateAtOffset(page, candidateOffset, &candidateController, &candidateFrontendRouter, &candidateBackendDispatcher);
        [candidateLines addObject:[NSString stringWithFormat:@"offset=%@ controller=%@ frontendRouter=%@ backendDispatcher=%@ valid=%@", WIKNativeInspectorProbe::offsetString(candidateOffset), WIKNativeInspectorProbe::pointerString(candidateController), WIKNativeInspectorProbe::pointerString(candidateFrontendRouter), WIKNativeInspectorProbe::pointerString(candidateBackendDispatcher), valid ? @"yes" : @"no"]];
        if (!valid)
            continue;

        validCandidateCount++;
        if (candidateOffset == WIKNativeInspectorProbe::webPageInspectorControllerOffset) {
            exactOffsetMatched = YES;
            controller = candidateController;
            frontendRouter = candidateFrontendRouter;
            backendDispatcher = candidateBackendDispatcher;
            resolvedControllerOffset = candidateOffset;
            break;
        }

        nearbyValidCandidateCount++;
        if (nearbyValidCandidateCount == 1) {
            controller = candidateController;
            frontendRouter = candidateFrontendRouter;
            backendDispatcher = candidateBackendDispatcher;
            resolvedControllerOffset = candidateOffset;
            validatedNearbyOffsetAccepted = YES;
        } else {
            controller = nullptr;
            frontendRouter = nullptr;
            backendDispatcher = nullptr;
            resolvedControllerOffset = NSNotFound;
            validatedNearbyOffsetAccepted = NO;
        }
    }

    NSString *controllerSource = exactOffsetMatched
        ? @"page + 0x4C0"
        : (validatedNearbyOffsetAccepted ? @"page + validated nearby offset" : (nearbyValidCandidateCount ? @"unresolved (multiple nearby candidates)" : @"unresolved"));
    NSString *selectorDiagnostics = [@[
        [NSString stringWithFormat:@"inspectorObject=%@", _inspector ? NSStringFromClass([_inspector class]) : @"nil"],
        [NSString stringWithFormat:@"pageFromGetter=%@", WIKNativeInspectorProbe::pointerString(pageFromGetter)],
        [NSString stringWithFormat:@"pageFromIvar=%@", WIKNativeInspectorProbe::pointerString(pageFromIvar)],
        [NSString stringWithFormat:@"WKWebView._page offset=%@", WIKNativeInspectorProbe::offsetString(webViewPageOffset)],
        [NSString stringWithFormat:@"pageGetterSkipped=%@", pageGetterSkipped ? @"yes" : @"no"],
        [NSString stringWithFormat:@"pageSourcesDisagree=%@", pageSourcesDisagree ? @"yes" : @"no"],
        [NSString stringWithFormat:@"page=%@", WIKNativeInspectorProbe::pointerString(page)],
        [NSString stringWithFormat:@"controller=%@", WIKNativeInspectorProbe::pointerString(controller)],
        [NSString stringWithFormat:@"frontendRouter=%@", WIKNativeInspectorProbe::pointerString(frontendRouter)],
        [NSString stringWithFormat:@"backendDispatcher=%@", WIKNativeInspectorProbe::pointerString(backendDispatcher)],
        [NSString stringWithFormat:@"resolvedControllerOffset=%@", WIKNativeInspectorProbe::offsetString(resolvedControllerOffset)],
        [NSString stringWithFormat:@"controllerSource=%@", controllerSource],
        [NSString stringWithFormat:@"validCandidateCount=%lu", static_cast<unsigned long>(validCandidateCount)],
        [NSString stringWithFormat:@"nearbyValidCandidateCount=%lu", static_cast<unsigned long>(nearbyValidCandidateCount)],
        [NSString stringWithFormat:@"exactOffsetMatched=%@", exactOffsetMatched ? @"yes" : @"no"],
        [NSString stringWithFormat:@"validatedNearbyOffsetAccepted=%@", validatedNearbyOffsetAccepted ? @"yes" : @"no"],
        @"controllerCandidates:",
        [candidateLines componentsJoinedByString:@"\n"],
    ] componentsJoinedByString:@"\n"];

    if (!exactOffsetMatched && !validatedNearbyOffsetAccepted) {
        controller = nullptr;
        frontendRouter = nullptr;
        backendDispatcher = nullptr;
        resolvedControllerOffset = NSNotFound;
    }

    _controller = controller;
    _backendDispatcher = backendDispatcher;

    if (!_inspector || !_controller || !_backendDispatcher) {
        NSString *message = WIKNativeInspectorProbe::selectorFailureMessage(_inspector, pageSourcesDisagree, page, exactOffsetMatched, nearbyValidCandidateCount, controller, backendDispatcher);
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
        [self finishWithStatus:WIKNativeInspectorProbe::failedStatus
                         stage:WIKNativeInspectorProbe::symbolStage
                       message:@"Missing private WebKit symbols required to attach the native frontend."
                     URLString:self.targetURLString
             requestIdentifier:nil
                   bodyPreview:nil
                 base64Encoded:NO
               rawBackendError:nil
                    rawMessage:nil];
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

    WTF::String payloadString(jsonString);
    WIKNativeInspectorProbe::backendDispatcherDispatch(_backendDispatcher, payloadString);
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

#endif
