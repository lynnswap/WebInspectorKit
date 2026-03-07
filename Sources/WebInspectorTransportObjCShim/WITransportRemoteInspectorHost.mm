#import "WITransportRemoteInspectorHost.h"

#import <TargetConditionals.h>

#if TARGET_OS_OSX

#import <AppKit/AppKit.h>
#import <objc/message.h>

namespace WITransportRemoteInspectorHostPrivate {

static NSString *const errorDomain = @"WebInspectorTransport.RemoteInspectorHost";
static constexpr NSInteger debuggableTypeWebPage = 4;

enum ErrorCode : NSInteger {
    ErrorCodeUnsupported = 1,
    ErrorCodeAttachFailed = 2,
    ErrorCodeNotAttached = 3,
    ErrorCodeVisibilityFailed = 4,
};

static NSError *makeError(ErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:errorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static id invokeObjectGetter(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return nil;

    using Getter = id (*)(id, SEL);
    __unsafe_unretained id value = reinterpret_cast<Getter>(objc_msgSend)(target, selector);
    return value;
}

static BOOL invokeObjectSetter(id target, NSString *selectorName, id value)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return NO;

    using Setter = void (*)(id, SEL, id);
    reinterpret_cast<Setter>(objc_msgSend)(target, selector, value);
    return YES;
}

static BOOL invokeIntegerSetter(id target, NSString *selectorName, NSInteger value)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return NO;

    using Setter = void (*)(id, SEL, NSInteger);
    reinterpret_cast<Setter>(objc_msgSend)(target, selector, value);
    return YES;
}

static BOOL invokeBoolSetter(id target, NSString *selectorName, BOOL value)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return NO;

    using Setter = void (*)(id, SEL, BOOL);
    reinterpret_cast<Setter>(objc_msgSend)(target, selector, value);
    return YES;
}

static BOOL invokeVoid(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return NO;

    using Invoker = void (*)(id, SEL);
    reinterpret_cast<Invoker>(objc_msgSend)(target, selector);
    return YES;
}

static id invokeInitWithConfiguration(Class controllerClass, id configuration)
{
    SEL selector = NSSelectorFromString(@"initWithConfiguration:");
    if (!controllerClass || ![controllerClass instancesRespondToSelector:selector])
        return nil;

    id controller = [controllerClass alloc];
    using Initializer = id (*)(id, SEL, id);
    return reinterpret_cast<Initializer>(objc_msgSend)(controller, selector, configuration);
}

static BOOL invokeLoadForDebuggable(id controller, id debuggableInfo, NSURL *backendCommandsURL)
{
    SEL selector = NSSelectorFromString(@"loadForDebuggable:backendCommandsURL:");
    if (!controller || ![controller respondsToSelector:selector])
        return NO;

    using Loader = void (*)(id, SEL, id, id);
    reinterpret_cast<Loader>(objc_msgSend)(controller, selector, debuggableInfo, backendCommandsURL);
    return YES;
}

static BOOL invokeSendMessageToFrontend(id controller, NSString *message)
{
    SEL selector = NSSelectorFromString(@"sendMessageToFrontend:");
    if (!controller || ![controller respondsToSelector:selector])
        return NO;

    using Sender = void (*)(id, SEL, id);
    reinterpret_cast<Sender>(objc_msgSend)(controller, selector, message);
    return YES;
}

static NSURL *inspectorBackendCommandsURL()
{
    Class inspectorViewControllerClass = NSClassFromString(@"WKInspectorViewController");
    SEL selector = NSSelectorFromString(@"URLForInspectorResource:");
    if (!inspectorViewControllerClass || ![inspectorViewControllerClass respondsToSelector:selector])
        return nil;

    using URLFactory = id (*)(id, SEL, id);
    return reinterpret_cast<URLFactory>(objc_msgSend)(inspectorViewControllerClass, selector, @"Protocol/InspectorBackendCommands.js");
}

static NSDictionary<NSString *, NSString *> *systemVersionInfo()
{
    NSDictionary<NSString *, NSString *> *plist = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
    if ([plist isKindOfClass:NSDictionary.class])
        return plist;
    return @{};
}

static NSString *availabilityFailureReason()
{
    Class configurationClass = NSClassFromString(@"_WKInspectorConfiguration");
    if (!configurationClass)
        return @"_WKInspectorConfiguration was unavailable.";

    Class debuggableInfoClass = NSClassFromString(@"_WKInspectorDebuggableInfo");
    if (!debuggableInfoClass)
        return @"_WKInspectorDebuggableInfo was unavailable.";

    Class controllerClass = NSClassFromString(@"_WKRemoteWebInspectorViewController");
    if (!controllerClass)
        return @"_WKRemoteWebInspectorViewController was unavailable.";

    if (![configurationClass instancesRespondToSelector:@selector(init)])
        return @"_WKInspectorConfiguration.init was unavailable.";
    if (![debuggableInfoClass instancesRespondToSelector:@selector(init)])
        return @"_WKInspectorDebuggableInfo.init was unavailable.";
    if (![controllerClass instancesRespondToSelector:NSSelectorFromString(@"initWithConfiguration:")])
        return @"_WKRemoteWebInspectorViewController.initWithConfiguration: was unavailable.";
    if (![controllerClass instancesRespondToSelector:NSSelectorFromString(@"loadForDebuggable:backendCommandsURL:")])
        return @"_WKRemoteWebInspectorViewController.loadForDebuggable:backendCommandsURL: was unavailable.";
    if (![controllerClass instancesRespondToSelector:NSSelectorFromString(@"sendMessageToFrontend:")])
        return @"_WKRemoteWebInspectorViewController.sendMessageToFrontend: was unavailable.";
    if (!inspectorBackendCommandsURL())
        return @"WKInspectorViewController.URLForInspectorResource: could not resolve InspectorBackendCommands.js.";

    return nil;
}

} // namespace WITransportRemoteInspectorHostPrivate

@interface WITransportRemoteInspectorHost ()

@property (nonatomic, weak, readonly) WKWebView *webView;
- (void)reportFatalFailure:(NSString *)message;
- (void)updateObservedWindow;
- (void)removeWindowObservers;
- (void)suppressInspectorWindowIfNeeded;
- (NSWindow *)currentInspectorWindow;
- (void)restorePreviousKeyWindowIfNeededForRemoteWindow:(NSWindow *)remoteWindow;

@end

@implementation WITransportRemoteInspectorHost {
    __weak WKWebView *_webView;
    id _remoteInspectorController;
    __weak NSWindow *_previousKeyWindow;
    __weak NSWindow *_observedWindow;
    id _windowDidBecomeKeyObserver;
    id _windowDidBecomeMainObserver;
    id _windowDidBecomeVisibleObserver;
    id _windowDidUpdateObserver;
}

+ (NSString *)availabilityFailureReason
{
    return WITransportRemoteInspectorHostPrivate::availabilityFailureReason();
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

- (BOOL)attach:(NSError * _Nullable __autoreleasing *)error
{
    [self detach];

    if (!self.webView) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeAttachFailed, @"WKWebView was released before remote inspector host attach.");
        return NO;
    }

    if (NSString *reason = WITransportRemoteInspectorHostPrivate::availabilityFailureReason()) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeUnsupported, reason);
        return NO;
    }

    Class configurationClass = NSClassFromString(@"_WKInspectorConfiguration");
    id configuration = [[configurationClass alloc] init];
    if (!configuration) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeAttachFailed, @"Unable to create _WKInspectorConfiguration.");
        return NO;
    }

    Class controllerClass = NSClassFromString(@"_WKRemoteWebInspectorViewController");
    id controller = WITransportRemoteInspectorHostPrivate::invokeInitWithConfiguration(controllerClass, configuration);
    if (!controller) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeAttachFailed, @"Unable to create _WKRemoteWebInspectorViewController.");
        return NO;
    }

    WITransportRemoteInspectorHostPrivate::invokeObjectSetter(controller, @"setDelegate:", self);

    Class debuggableInfoClass = NSClassFromString(@"_WKInspectorDebuggableInfo");
    id debuggableInfo = [[debuggableInfoClass alloc] init];
    if (!debuggableInfo) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeAttachFailed, @"Unable to create _WKInspectorDebuggableInfo.");
        return NO;
    }

    auto systemVersionInfo = WITransportRemoteInspectorHostPrivate::systemVersionInfo();
    WITransportRemoteInspectorHostPrivate::invokeIntegerSetter(debuggableInfo, @"setDebuggableType:", WITransportRemoteInspectorHostPrivate::debuggableTypeWebPage);
    WITransportRemoteInspectorHostPrivate::invokeObjectSetter(debuggableInfo, @"setTargetPlatformName:", @"macOS");
    WITransportRemoteInspectorHostPrivate::invokeObjectSetter(debuggableInfo, @"setTargetProductVersion:", systemVersionInfo[@"ProductVersion"] ?: @"");
    WITransportRemoteInspectorHostPrivate::invokeObjectSetter(debuggableInfo, @"setTargetBuildVersion:", systemVersionInfo[@"ProductBuildVersion"] ?: @"");
    WITransportRemoteInspectorHostPrivate::invokeBoolSetter(debuggableInfo, @"setTargetIsSimulator:", NO);

    NSURL *backendCommandsURL = WITransportRemoteInspectorHostPrivate::inspectorBackendCommandsURL();
    if (!backendCommandsURL) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeAttachFailed, @"Unable to resolve the InspectorBackendCommands.js resource URL.");
        return NO;
    }

    _previousKeyWindow = NSApp.keyWindow ?: self.webView.window;
    _remoteInspectorController = controller;

    if (!WITransportRemoteInspectorHostPrivate::invokeLoadForDebuggable(controller, debuggableInfo, backendCommandsURL)) {
        _remoteInspectorController = nil;
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeAttachFailed, @"Unable to load the remote inspector frontend.");
        return NO;
    }

    [self updateObservedWindow];
    [self suppressInspectorWindowIfNeeded];
    if (self.windowVisible || self.windowKey || self.windowMain) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeVisibilityFailed, @"The remote inspector window could not be kept hidden.");
        [self detach];
        return NO;
    }

    return YES;
}

- (BOOL)sendMessageToFrontend:(NSString *)message error:(NSError * _Nullable __autoreleasing *)error
{
    if (!_remoteInspectorController) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeNotAttached, @"The remote inspector host is not attached.");
        return NO;
    }

    if (!message.length)
        return YES;

    if (!WITransportRemoteInspectorHostPrivate::invokeSendMessageToFrontend(_remoteInspectorController, message)) {
        if (error)
            *error = WITransportRemoteInspectorHostPrivate::makeError(WITransportRemoteInspectorHostPrivate::ErrorCodeAttachFailed, @"Unable to mirror the backend message into the remote inspector frontend.");
        return NO;
    }

    [self performVisibilityMaintenance];
    return YES;
}

- (void)performVisibilityMaintenance
{
    [self updateObservedWindow];
    [self suppressInspectorWindowIfNeeded];
}

- (void)detach
{
    [self removeWindowObservers];

    if (_remoteInspectorController) {
        WITransportRemoteInspectorHostPrivate::invokeObjectSetter(_remoteInspectorController, @"setDelegate:", nil);
        [self suppressInspectorWindowIfNeeded];
        WITransportRemoteInspectorHostPrivate::invokeVoid(_remoteInspectorController, @"close");
    }

    _remoteInspectorController = nil;
    _previousKeyWindow = nil;
    _observedWindow = nil;
}

- (BOOL)isWindowVisible
{
    return self.currentInspectorWindow.isVisible;
}

- (BOOL)isWindowKey
{
    return self.currentInspectorWindow.isKeyWindow;
}

- (BOOL)isWindowMain
{
    return self.currentInspectorWindow.isMainWindow;
}

- (NSWindow *)currentInspectorWindow
{
    id window = WITransportRemoteInspectorHostPrivate::invokeObjectGetter(_remoteInspectorController, @"window");
    return [window isKindOfClass:NSWindow.class] ? window : nil;
}

- (void)updateObservedWindow
{
    NSWindow *window = self.currentInspectorWindow;
    if (!window || window == _observedWindow)
        return;

    [self removeWindowObservers];
    _observedWindow = window;

    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    _windowDidBecomeKeyObserver = [center addObserverForName:NSWindowDidBecomeKeyNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
        [weakSelf performVisibilityMaintenance];
    }];
    _windowDidBecomeMainObserver = [center addObserverForName:NSWindowDidBecomeMainNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
        [weakSelf performVisibilityMaintenance];
    }];
    _windowDidBecomeVisibleObserver = [center addObserverForName:NSWindowDidExposeNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
        [weakSelf performVisibilityMaintenance];
    }];
    _windowDidUpdateObserver = [center addObserverForName:NSWindowDidUpdateNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
        [weakSelf performVisibilityMaintenance];
    }];
}

- (void)removeWindowObservers
{
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_windowDidBecomeKeyObserver)
        [center removeObserver:_windowDidBecomeKeyObserver];
    if (_windowDidBecomeMainObserver)
        [center removeObserver:_windowDidBecomeMainObserver];
    if (_windowDidBecomeVisibleObserver)
        [center removeObserver:_windowDidBecomeVisibleObserver];
    if (_windowDidUpdateObserver)
        [center removeObserver:_windowDidUpdateObserver];
    _windowDidBecomeKeyObserver = nil;
    _windowDidBecomeMainObserver = nil;
    _windowDidBecomeVisibleObserver = nil;
    _windowDidUpdateObserver = nil;
}

- (void)suppressInspectorWindowIfNeeded
{
    NSWindow *window = self.currentInspectorWindow;
    if (!window)
        return;

    if (window.isVisible || window.isKeyWindow || window.isMainWindow) {
        [window orderOut:nil];
        [self restorePreviousKeyWindowIfNeededForRemoteWindow:window];
    }

    if (window.isVisible || window.isKeyWindow || window.isMainWindow)
        [self reportFatalFailure:@"The remote inspector window became visible while hidden-only mode was required."];
}

- (void)restorePreviousKeyWindowIfNeededForRemoteWindow:(NSWindow *)remoteWindow
{
    NSWindow *candidate = _previousKeyWindow;
    if (!candidate || candidate == remoteWindow || !candidate.isVisible)
        candidate = self.webView.window;
    if (candidate && candidate != remoteWindow && candidate.isVisible) {
        [NSApp activateIgnoringOtherApps:YES];
        [candidate orderFrontRegardless];
        [candidate makeKeyWindow];
    }
}

- (void)reportFatalFailure:(NSString *)message
{
    WITransportRemoteInspectorFatalFailureHandler handler = self.fatalFailureHandler;
    if (handler)
        handler(message);
}

- (void)inspectorViewController:(__unused id)controller sendMessageToBackend:(NSString *)message
{
    WITransportRemoteInspectorBackendMessageHandler handler = self.backendMessageHandler;
    if (handler)
        handler(message);
}

- (void)inspectorViewControllerInspectorDidClose:(__unused id)controller
{
    [self reportFatalFailure:@"The remote inspector frontend closed unexpectedly."];
}

@end

extern "C" NSString * _Nullable WITransportRemoteInspectorHostAvailabilityFailureReason(void)
{
    return [WITransportRemoteInspectorHost availabilityFailureReason];
}

extern "C" NSObject * _Nullable WITransportCreateRemoteInspectorHost(WKWebView *webView)
{
    return [[WITransportRemoteInspectorHost alloc] initWithWebView:webView];
}

extern "C" void WITransportRemoteInspectorHostSetBackendMessageHandler(NSObject *host, WITransportRemoteInspectorBackendMessageHandler _Nullable handler)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    typedHost.backendMessageHandler = handler;
}

extern "C" void WITransportRemoteInspectorHostSetFatalFailureHandler(NSObject *host, WITransportRemoteInspectorFatalFailureHandler _Nullable handler)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    typedHost.fatalFailureHandler = handler;
}

extern "C" BOOL WITransportRemoteInspectorHostAttach(NSObject *host, NSError * _Nullable __autoreleasing * _Nullable error)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    return [typedHost attach:error];
}

extern "C" BOOL WITransportRemoteInspectorHostSendMessageToFrontend(NSObject *host, NSString *message, NSError * _Nullable __autoreleasing * _Nullable error)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    return [typedHost sendMessageToFrontend:message error:error];
}

extern "C" void WITransportRemoteInspectorHostPerformVisibilityMaintenance(NSObject *host)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    [typedHost performVisibilityMaintenance];
}

extern "C" BOOL WITransportRemoteInspectorHostIsWindowVisible(NSObject *host)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    return typedHost.isWindowVisible;
}

extern "C" BOOL WITransportRemoteInspectorHostIsWindowKey(NSObject *host)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    return typedHost.isWindowKey;
}

extern "C" BOOL WITransportRemoteInspectorHostIsWindowMain(NSObject *host)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    return typedHost.isWindowMain;
}

extern "C" void WITransportRemoteInspectorHostDetach(NSObject *host)
{
    WITransportRemoteInspectorHost *typedHost = [host isKindOfClass:WITransportRemoteInspectorHost.class] ? static_cast<WITransportRemoteInspectorHost *>(host) : nil;
    [typedHost detach];
}

#endif
