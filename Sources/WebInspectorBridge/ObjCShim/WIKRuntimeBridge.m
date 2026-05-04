#import "WIKRuntimeBridge.h"
#import "WKWebView+EvaluateJavaScriptCompat.h"

#if TARGET_OS_OSX
#import <objc/runtime.h>
#endif

typedef const struct OpaqueWKFrameHandle *WKFrameHandleRef;
typedef const struct OpaqueWKPage *WKPageRef;

NSErrorDomain const WIKRuntimeBridgeErrorDomain = @"WebInspectorBridge.WIKRuntimeBridge";

static NSString *WIKRuntimeBridgeStringFromReverseTokens(NSArray<NSString *> *reverseTokens)
{
    NSMutableString *string = [NSMutableString string];
    for (NSString *token in [reverseTokens reverseObjectEnumerator])
        [string appendString:token];
    return [string copy];
}

static SEL WIKRuntimeBridgeSelectorFromReverseTokens(NSArray<NSString *> *reverseTokens)
{
    return NSSelectorFromString(WIKRuntimeBridgeStringFromReverseTokens(reverseTokens));
}

static NSObject *WIKRuntimeBridgeObjectResult(id target, SEL selector)
{
    if (![target respondsToSelector:selector])
        return nil;

    typedef id (*Getter)(id, SEL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL)
        return nil;

    Getter function = (Getter)implementation;
    id result = function(target, selector);
    return [result isKindOfClass:[NSObject class]] ? result : nil;
}

static NSNumber *WIKRuntimeBridgeBoolResult(id target, SEL selector)
{
    if (![target respondsToSelector:selector])
        return nil;

    typedef BOOL (*Getter)(id, SEL);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL)
        return nil;

    Getter function = (Getter)implementation;
    return @(function(target, selector));
}

static BOOL WIKRuntimeBridgeInvokeVoid(id target, SEL selector)
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

static BOOL WIKRuntimeBridgeInvokeObject(id target, SEL selector, id object)
{
    if (![target respondsToSelector:selector])
        return NO;

    typedef void (*Invoker)(id, SEL, id);
    IMP implementation = [target methodForSelector:selector];
    if (implementation == NULL)
        return NO;

    Invoker function = (Invoker)implementation;
    function(target, selector, object);
    return YES;
}

#if TARGET_OS_IPHONE
@interface WIKInspectorNodeSearchCommitGestureRecognizer : UIGestureRecognizer
- (instancetype)initWithContentView:(UIView *)contentView;
@end

@interface WIKInspectorNodeSearchCommitGestureRecognizer ()
@property (nonatomic, weak) UIView *contentView;
@property (nonatomic) CGPoint initialLocation;
@property (nonatomic) BOOL hasInitialLocation;
@property (nonatomic) BOOL didMoveBeyondTapTolerance;
- (void)wi_commitInspectorNodeSearchIfPossible;
@end

@implementation WIKInspectorNodeSearchCommitGestureRecognizer

static const CGFloat WIKInspectorNodeSearchCommitMovementThreshold = 3.0;

- (instancetype)initWithContentView:(UIView *)contentView
{
    self = [super initWithTarget:nil action:nil];
    if (!self)
        return nil;

    _contentView = contentView;
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    return self;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer
{
    return NO;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer
{
    return NO;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (touches.count != 1) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }

    UIView *contentView = self.contentView ?: self.view;
    self.initialLocation = [[touches anyObject] locationInView:contentView];
    self.hasInitialLocation = YES;
    self.didMoveBeyondTapTolerance = NO;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (!self.hasInitialLocation || self.state != UIGestureRecognizerStatePossible)
        return;

    UIView *contentView = self.contentView ?: self.view;
    CGPoint location = [[touches anyObject] locationInView:contentView];
    CGFloat deltaX = location.x - self.initialLocation.x;
    CGFloat deltaY = location.y - self.initialLocation.y;
    CGFloat squaredDistance = deltaX * deltaX + deltaY * deltaY;
    CGFloat threshold = WIKInspectorNodeSearchCommitMovementThreshold;
    if (squaredDistance >= threshold * threshold)
        self.didMoveBeyondTapTolerance = YES;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (self.state != UIGestureRecognizerStatePossible)
        return;

    if (!self.didMoveBeyondTapTolerance) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }

    self.state = UIGestureRecognizerStateRecognized;
    [self wi_commitInspectorNodeSearchIfPossible];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset
{
    [super reset];
    self.hasInitialLocation = NO;
    self.didMoveBeyondTapTolerance = NO;
    self.initialLocation = CGPointZero;
}

- (void)wi_commitInspectorNodeSearchIfPossible
{
    UIView *contentView = self.contentView ?: self.view;
    if (!contentView)
        return;

    SEL selector = WIKRuntimeBridgeSelectorFromReverseTokens(
        @[@":", @"Recognized", @"Search", @"Node", @"inspector", @"_"]
    );
    WIKRuntimeBridgeInvokeObject(contentView, selector, self);
}

@end
#endif

@implementation WIKRuntimeBridge

#if TARGET_OS_IPHONE
+ (nullable Class)wi_contentViewClass
{
    static Class contentViewClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *className = WIKRuntimeBridgeStringFromReverseTokens(@[@"View", @"Content", @"WK"]);
        contentViewClass = NSClassFromString(className);
    });
    return contentViewClass;
}

+ (nullable Class)wi_inspectorNodeSearchRecognizerClass
{
    static Class recognizerClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *className = WIKRuntimeBridgeStringFromReverseTokens(
            @[@"Recognizer", @"Gesture", @"Search", @"Node", @"Inspector", @"WK"]
        );
        recognizerClass = NSClassFromString(className);
    });
    return recognizerClass;
}

+ (Class)wi_inspectorNodeSearchCommitRecognizerClass
{
    return [WIKInspectorNodeSearchCommitGestureRecognizer class];
}

+ (BOOL)wi_contentViewHasInspectorNodeSearchRecognizer:(UIView *)contentView
{
    Class recognizerClass = [self wi_inspectorNodeSearchRecognizerClass];
    if (!recognizerClass)
        return NO;

    for (UIGestureRecognizer *recognizer in contentView.gestureRecognizers) {
        if ([recognizer isKindOfClass:recognizerClass])
            return YES;
    }

    return NO;
}

+ (BOOL)wi_contentViewHasInspectorNodeSearchCommitRecognizer:(UIView *)contentView
{
    Class recognizerClass = [self wi_inspectorNodeSearchCommitRecognizerClass];
    for (UIGestureRecognizer *recognizer in contentView.gestureRecognizers) {
        if ([recognizer isKindOfClass:recognizerClass])
            return YES;
    }

    return NO;
}

+ (BOOL)wi_installInspectorNodeSearchCommitRecognizerInContentView:(UIView *)contentView
{
    if ([self wi_contentViewHasInspectorNodeSearchCommitRecognizer:contentView])
        return NO;

    WIKInspectorNodeSearchCommitGestureRecognizer *recognizer =
        [[WIKInspectorNodeSearchCommitGestureRecognizer alloc] initWithContentView:contentView];
    [contentView addGestureRecognizer:recognizer];
    return YES;
}

+ (BOOL)wi_removeInspectorNodeSearchCommitRecognizersInContentView:(UIView *)contentView
{
    BOOL didRemoveRecognizer = NO;
    Class recognizerClass = [self wi_inspectorNodeSearchCommitRecognizerClass];
    for (UIGestureRecognizer *recognizer in [contentView.gestureRecognizers copy]) {
        if (![recognizer isKindOfClass:recognizerClass])
            continue;
        recognizer.enabled = NO;
        [contentView removeGestureRecognizer:recognizer];
        didRemoveRecognizer = YES;
    }
    return didRemoveRecognizer;
}

+ (nullable UIView *)wi_firstContentViewInView:(UIView *)view
{
    Class contentViewClass = [self wi_contentViewClass];
    if (contentViewClass && [view isKindOfClass:contentViewClass])
        return view;

    for (UIView *subview in view.subviews) {
        UIView *contentView = [self wi_firstContentViewInView:subview];
        if (contentView)
            return contentView;
    }

    return nil;
}

+ (void)wi_appendContentViewsInView:(UIView *)view toArray:(NSMutableArray<UIView *> *)contentViews
{
    Class contentViewClass = [self wi_contentViewClass];
    if (contentViewClass && [view isKindOfClass:contentViewClass])
        [contentViews addObject:view];

    for (UIView *subview in view.subviews)
        [self wi_appendContentViewsInView:subview toArray:contentViews];
}

+ (NSArray<UIView *> *)wi_contentViewsForWebView:(WKWebView *)webView
{
    NSMutableArray<UIView *> *contentViews = [NSMutableArray array];
    [self wi_appendContentViewsInView:webView toArray:contentViews];
    return [contentViews copy];
}

+ (nullable UIView *)wi_preferredContentViewForWebView:(WKWebView *)webView
{
    NSArray<UIView *> *contentViews = [self wi_contentViewsForWebView:webView];
    if (contentViews.count == 0)
        return nil;

    for (UIView *contentView in [contentViews reverseObjectEnumerator]) {
        if (!CGRectIsEmpty(contentView.bounds) && !contentView.hidden && contentView.alpha > 0.0)
            return contentView;
    }

    return contentViews.lastObject;
}

+ (nullable UIView *)wi_currentContentViewForWebView:(WKWebView *)webView
{
    NSString *selectorName = WIKRuntimeBridgeStringFromReverseTokens(@[@"View", @"Content", @"current", @"_"]);
    SEL selector = NSSelectorFromString(selectorName);
    if (![webView respondsToSelector:selector])
        return nil;

    id result = [self objectResultFromTarget:webView selectorName:selectorName];
    if (![result isKindOfClass:[UIView class]])
        return nil;

    Class contentViewClass = [self wi_contentViewClass];
    if (contentViewClass && ![result isKindOfClass:contentViewClass])
        return nil;

    return (UIView *)result;
}

+ (nullable UIView *)wi_activeContentViewForWebView:(WKWebView *)webView
{
    UIView *contentView = [self wi_currentContentViewForWebView:webView];
    if (contentView)
        return contentView;

    return [self wi_preferredContentViewForWebView:webView];
}

+ (nullable NSObject *)inspectorForWebView:(WKWebView *)webView
{
    return [self objectResultFromTarget:webView
                           selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"inspector", @"_"])];
}

+ (nullable NSNumber *)inspectorElementSelectionActiveForWebView:(WKWebView *)webView
{
    NSObject *inspector = [self inspectorForWebView:webView];
    if (!inspector)
        return nil;

    return [self boolResultFromTarget:inspector
                         selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"Active", @"Selection", @"Element", @"is"])];
}

+ (nullable NSNumber *)inspectorConnectedForWebView:(WKWebView *)webView
{
    NSObject *inspector = [self inspectorForWebView:webView];
    if (!inspector)
        return nil;

    return [self boolResultFromTarget:inspector
                         selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"Connected", @"is"])];
}

+ (BOOL)connectInspectorForWebView:(WKWebView *)webView
{
    NSObject *inspector = [self inspectorForWebView:webView];
    if (!inspector)
        return NO;

    if ([[self inspectorConnectedForWebView:webView] boolValue])
        return YES;

    BOOL didInvokeConnect = [self invokeVoidOnTarget:inspector
                                        selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"connect"])];
    NSNumber *connected = [self inspectorConnectedForWebView:webView];
    if (connected)
        return connected.boolValue;

    BOOL didInvokeAttach = [self invokeVoidOnTarget:inspector
                                       selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"attach"])];
    connected = [self inspectorConnectedForWebView:webView];
    if (connected)
        return connected.boolValue;

    return didInvokeConnect || didInvokeAttach;
}

+ (BOOL)toggleInspectorElementSelectionForWebView:(WKWebView *)webView
{
    NSObject *inspector = [self inspectorForWebView:webView];
    if (!inspector)
        return NO;

    return [self invokeVoidOnTarget:inspector
                       selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"Selection", @"Element", @"toggle"])];
}

+ (nullable NSNumber *)showingInspectorIndicationForWebView:(WKWebView *)webView
{
    UIView *contentView = [self wi_activeContentViewForWebView:webView];
    if (!contentView)
        return nil;

    return [self boolResultFromTarget:contentView
                         selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"Indication", @"Inspector", @"Showing", @"is"])];
}

+ (BOOL)setShowingInspectorIndication:(BOOL)showingInspectorIndication
                           forWebView:(WKWebView *)webView
{
    UIView *contentView = [self wi_activeContentViewForWebView:webView];
    if (!contentView)
        return NO;

    SEL selector = WIKRuntimeBridgeSelectorFromReverseTokens(
        @[@":", @"Indication", @"Inspector", @"Showing", @"set"]
    );
    if (![contentView respondsToSelector:selector])
        return NO;

    typedef void (*Setter)(id, SEL, BOOL);
    IMP implementation = [contentView methodForSelector:selector];
    if (implementation == NULL)
        return NO;

    Setter function = (Setter)implementation;
    function(contentView, selector, showingInspectorIndication);
    return YES;
}

+ (BOOL)canEnableInspectorNodeSearchForWebView:(WKWebView *)webView
{
    UIView *contentView = [self wi_activeContentViewForWebView:webView];
    SEL selector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@"Search", @"Node", @"Inspector", @"enable", @"_"]);
    return contentView && [contentView respondsToSelector:selector];
}

+ (BOOL)enableInspectorNodeSearchForWebView:(WKWebView *)webView
{
    UIView *activeContentView = [self wi_activeContentViewForWebView:webView];
    SEL enableSelector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@"Search", @"Node", @"Inspector", @"enable", @"_"]);
    SEL disableSelector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@"Search", @"Node", @"Inspector", @"disable", @"_"]);
    if (!activeContentView || ![activeContentView respondsToSelector:enableSelector])
        return NO;

    for (UIView *contentView in [self wi_contentViewsForWebView:webView]) {
        if (contentView == activeContentView)
            continue;
        WIKRuntimeBridgeInvokeVoid(contentView, disableSelector);
        [self wi_removeInspectorNodeSearchCommitRecognizersInContentView:contentView];
    }

    if ([self wi_contentViewHasInspectorNodeSearchRecognizer:activeContentView]) {
        [self wi_installInspectorNodeSearchCommitRecognizerInContentView:activeContentView];
        return YES;
    }

    WIKRuntimeBridgeInvokeVoid(activeContentView, enableSelector);
    [self wi_installInspectorNodeSearchCommitRecognizerInContentView:activeContentView];
    return YES;
}

+ (BOOL)disableInspectorNodeSearchForWebView:(WKWebView *)webView
{
    BOOL didDisable = NO;
    SEL disableSelector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@"Search", @"Node", @"Inspector", @"disable", @"_"]);
    for (UIView *contentView in [self wi_contentViewsForWebView:webView]) {
        if (WIKRuntimeBridgeInvokeVoid(contentView, disableSelector))
            didDisable = YES;
        didDisable = [self wi_removeInspectorNodeSearchCommitRecognizersInContentView:contentView] || didDisable;
    }
    return didDisable;
}

+ (BOOL)hasInspectorNodeSearchRecognizerForWebView:(WKWebView *)webView
{
    UIView *contentView = [self wi_activeContentViewForWebView:webView];
    if (!contentView)
        return NO;

    return [self wi_contentViewHasInspectorNodeSearchRecognizer:contentView];
}

+ (BOOL)removeInspectorNodeSearchRecognizersFromWebView:(WKWebView *)webView
{
    Class recognizerClass = [self wi_inspectorNodeSearchRecognizerClass];

    BOOL didRemoveRecognizer = NO;
    for (UIView *contentView in [self wi_contentViewsForWebView:webView]) {
        for (UIGestureRecognizer *recognizer in [contentView.gestureRecognizers copy]) {
            BOOL isNodeSearchRecognizer = recognizerClass && [recognizer isKindOfClass:recognizerClass];
            BOOL isCommitRecognizer = [recognizer isKindOfClass:[self wi_inspectorNodeSearchCommitRecognizerClass]];
            if (!isNodeSearchRecognizer && !isCommitRecognizer)
                continue;
            recognizer.enabled = NO;
            [contentView removeGestureRecognizer:recognizer];
            didRemoveRecognizer = YES;
        }
    }
    return didRemoveRecognizer;
}

+ (nullable NSString *)nodeSearchDebugSummaryForWebView:(WKWebView *)webView
{
    NSArray<UIView *> *contentViews = [self wi_contentViewsForWebView:webView];
    UIView *currentContentView = [self wi_currentContentViewForWebView:webView];
    UIView *activeContentView = [self wi_activeContentViewForWebView:webView];

    NSUInteger recognizerViewCount = 0;
    NSUInteger commitRecognizerViewCount = 0;
    for (UIView *contentView in contentViews) {
        if ([self wi_contentViewHasInspectorNodeSearchRecognizer:contentView])
            recognizerViewCount += 1;
        if ([self wi_contentViewHasInspectorNodeSearchCommitRecognizer:contentView])
            commitRecognizerViewCount += 1;
    }

    BOOL activeHasNodeSearch = activeContentView && [self wi_contentViewHasInspectorNodeSearchRecognizer:activeContentView];
    BOOL activeHasCommit = activeContentView && [self wi_contentViewHasInspectorNodeSearchCommitRecognizer:activeContentView];
    BOOL anyHasNodeSearch = recognizerViewCount > 0;
    NSString *activeSource = currentContentView ? @"current" : @"fallback";

    return [NSString stringWithFormat:
        @"activeSource=%@ contentViews=%lu recognizerViews=%lu commitRecognizerViews=%lu activeHasNodeSearch=%d activeHasCommit=%d anyHasNodeSearch=%d",
        activeSource,
        (unsigned long)contentViews.count,
        (unsigned long)recognizerViewCount,
        (unsigned long)commitRecognizerViewCount,
        activeHasNodeSearch ? 1 : 0,
        activeHasCommit ? 1 : 0,
        anyHasNodeSearch ? 1 : 0
    ];
}
#endif

+ (NSObject *)objectResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName {
    return WIKRuntimeBridgeObjectResult(target, NSSelectorFromString(selectorName));
}

+ (NSNumber *)boolResultFromTarget:(NSObject *)target selectorName:(NSString *)selectorName {
    return WIKRuntimeBridgeBoolResult(target, NSSelectorFromString(selectorName));
}

+ (BOOL)invokeVoidOnTarget:(NSObject *)target selectorName:(NSString *)selectorName {
    return WIKRuntimeBridgeInvokeVoid(target, NSSelectorFromString(selectorName));
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

    SEL selector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@"ID", @"frame"]);
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

    id handle = [self objectResultFromTarget:frameInfo
                                selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"handle", @"_"])];
    return [self frameIDForHandle:handle];
}

+ (WKPageRef)pageRefForWebView:(WKWebView *)webView {
    SEL selector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@"Testing", @"For", @"page", @"_"]);
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
    id handle = [self objectResultFromTarget:frameInfo
                                selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"handle", @"_"])];
    if (![handle isKindOfClass:[NSObject class]]) {
        return NULL;
    }
    // The frame-lookup C API unwraps the Objective-C WKObject wrapper internally.
    // Passing the unwrapped pointer here crashes because it is no longer an Objective-C object.
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

    id frameInfo = [self objectResultFromTarget:node
                                   selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"info"])];
    if ([frameInfo isKindOfClass:[WKFrameInfo class]]) {
        [self appendFrameInfoIfNeeded:frameInfo frameInfos:frameInfos seenFrameIDs:seenFrameIDs];
    }

    id childFrames = [self objectResultFromTarget:node
                                     selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"Frames", @"child"])];
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
    id mainFrameHandle = [self objectResultFromTarget:webView
                                         selectorName:WIKRuntimeBridgeStringFromReverseTokens(@[@"Frame", @"main", @"_"])];
    if (!mainFrameHandle) {
        completionHandler(nil);
        return;
    }

    SEL selector = WIKRuntimeBridgeSelectorFromReverseTokens(
        @[@":", @"Handler", @"completion", @":", @"Handle", @"From", @"Info", @"frame", @"_"]
    );
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
    SEL selector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@":", @"Trees", @"frame", @"_"]);
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

    SEL framesSelector = WIKRuntimeBridgeSelectorFromReverseTokens(@[@":", @"frames", @"_"]);
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

+ (void)evaluateJavaScriptOnWebView:(WKWebView *)webView
                         javaScript:(NSString *)javaScript
                            inFrame:(WKFrameInfo *)frame
                     inContentWorld:(WKContentWorld *)contentWorld
                  completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler
{
    [webView wi_evaluateJavaScript:javaScript inFrame:frame inContentWorld:contentWorld completionHandler:completionHandler];
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

    NSString *controlIvarName = WIKRuntimeBridgeStringFromReverseTokens(@[@"control", @"_"]);
    Ivar controlIvar = class_getInstanceVariable(NSMenuToolbarItem.class, controlIvarName.UTF8String);
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
