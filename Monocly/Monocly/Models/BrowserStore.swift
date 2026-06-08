import Combine
import Foundation
import Observation
import OSLog
import WebKit

#if canImport(UIKit)
import UIKit
typealias BrowserPlatformColor = UIColor

enum BrowserViewportChromeGeometry {
    static func topEdgeOverlapHeight(hostFrame: CGRect, chromeFrame: CGRect) -> CGFloat {
        let overlap = hostFrame.intersection(chromeFrame)
        guard overlap.isNull == false else {
            return 0
        }
        guard chromeFrame.minY <= hostFrame.minY else {
            return 0
        }
        return max(0, overlap.maxY - hostFrame.minY)
    }

    static func bottomEdgeOverlapHeight(hostFrame: CGRect, chromeFrame: CGRect) -> CGFloat {
        let overlap = hostFrame.intersection(chromeFrame)
        guard overlap.isNull == false else {
            return 0
        }
        guard chromeFrame.maxY >= hostFrame.maxY else {
            return 0
        }
        return max(0, hostFrame.maxY - overlap.minY)
    }
}

#if os(iOS)
import WKViewportCoordinator
typealias BrowserViewportCoordinator = ViewportCoordinator
#else
@MainActor
final class BrowserViewportCoordinator {
    weak var hostViewController: UIViewController?
    private weak var webView: WKWebView?
    private var lastAppliedInsets: UIEdgeInsets?
    private var keyboardFrameInScreen: CGRect = .null
    private var lastKnownWindowIdentity: ObjectIdentifier?

    init(webView: WKWebView) {
        self.webView = webView
        observeKeyboardNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func invalidate() {
        guard let webView else {
            return
        }
        lastAppliedInsets = nil
        hostViewController?.setContentScrollView(nil)
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.contentInset = .zero
        webView.scrollView.verticalScrollIndicatorInsets = .zero
        webView.scrollView.horizontalScrollIndicatorInsets = .zero
    }

    func webViewHierarchyDidChange() {
        if let currentWindowIdentity = webView?.window.map(ObjectIdentifier.init) {
            if let lastKnownWindowIdentity, lastKnownWindowIdentity != currentWindowIdentity {
                keyboardFrameInScreen = .null
            }
            self.lastKnownWindowIdentity = currentWindowIdentity
        }
        updateViewport()
    }

    func hostViewDidAppear() {
        updateViewport()
    }

    func webViewSafeAreaInsetsDidChange() {
        updateViewport()
    }

    func updateViewport() {
        guard let webView else {
            return
        }
        guard let hostView = webView.superview else {
            invalidate()
            return
        }
        let safeAreaInsets = projectedWindowSafeAreaInsets(in: hostView)
        let topOverlap = topChromeObscuredHeight(in: hostViewController, hostView: hostView)
        let bottomOverlap = max(
            bottomChromeObscuredHeight(in: hostViewController, hostView: hostView),
            keyboardOverlapHeight(in: hostView)
        )
        let resolvedInsets = UIEdgeInsets(
            top: max(0, topOverlap - safeAreaInsets.top),
            left: 0,
            bottom: max(0, bottomOverlap - safeAreaInsets.bottom),
            right: 0
        )
        if lastAppliedInsets != resolvedInsets {
            lastAppliedInsets = resolvedInsets
            webView.scrollView.contentInset = resolvedInsets
            webView.scrollView.verticalScrollIndicatorInsets = resolvedInsets
            webView.scrollView.horizontalScrollIndicatorInsets = resolvedInsets
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        hostViewController?.setContentScrollView(webView.scrollView)
    }

    private func observeKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameNotification(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameNotification(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc
    private func handleKeyboardFrameNotification(_ notification: Notification) {
        let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .null
        keyboardFrameInScreen = keyboardFrame
        updateViewport()
    }

    private func projectedWindowSafeAreaInsets(in hostView: UIView?) -> UIEdgeInsets {
        guard let hostView, let window = hostView.window else {
            return .zero
        }

        let hostRectInWindow = hostView.convert(hostView.bounds, to: window)
        let safeRectInWindow = window.bounds.inset(by: window.safeAreaInsets)

        return UIEdgeInsets(
            top: max(0, safeRectInWindow.minY - hostRectInWindow.minY),
            left: max(0, safeRectInWindow.minX - hostRectInWindow.minX),
            bottom: max(0, hostRectInWindow.maxY - safeRectInWindow.maxY),
            right: max(0, hostRectInWindow.maxX - safeRectInWindow.maxX)
        )
    }

    private func topChromeObscuredHeight(in hostViewController: UIViewController?, hostView: UIView?) -> CGFloat {
        topEdgeObscuredHeight(of: hostViewController?.navigationController?.navigationBar, in: hostView)
    }

    private func bottomChromeObscuredHeight(in hostViewController: UIViewController?, hostView: UIView?) -> CGFloat {
        let tabBarOverlap = bottomEdgeObscuredHeight(of: hostViewController?.tabBarController?.tabBar, in: hostView)
        let toolbarOverlap = bottomEdgeObscuredHeight(of: resolvedVisibleToolbar(for: hostViewController), in: hostView)
        return max(tabBarOverlap, toolbarOverlap)
    }

    private func resolvedVisibleToolbar(for hostViewController: UIViewController?) -> UIToolbar? {
        guard let navigationController = hostViewController?.navigationController else {
            return nil
        }
        guard navigationController.isToolbarHidden == false else {
            return nil
        }
        return navigationController.toolbar
    }

    private func topEdgeObscuredHeight(of chromeView: UIView?, in hostView: UIView?) -> CGFloat {
        guard let chromeView, let hostView else {
            return 0
        }
        guard let window = hostView.window, chromeView.window != nil else {
            return 0
        }
        guard chromeView.isHidden == false, effectiveAlpha(of: chromeView) > 0 else {
            return 0
        }

        let hostFrameInWindow = hostView.convert(hostView.bounds, to: window)
        let chromeFrameInWindow = chromeView.convert(chromeView.bounds, to: window)
        return BrowserViewportChromeGeometry.topEdgeOverlapHeight(
            hostFrame: hostFrameInWindow,
            chromeFrame: chromeFrameInWindow
        )
    }

    private func bottomEdgeObscuredHeight(of chromeView: UIView?, in hostView: UIView?) -> CGFloat {
        guard let chromeView, let hostView else {
            return 0
        }
        guard let window = hostView.window, chromeView.window != nil else {
            return 0
        }
        guard chromeView.isHidden == false, effectiveAlpha(of: chromeView) > 0 else {
            return 0
        }

        let hostFrameInWindow = hostView.convert(hostView.bounds, to: window)
        let chromeFrameInWindow = chromeView.convert(chromeView.bounds, to: window)
        return BrowserViewportChromeGeometry.bottomEdgeOverlapHeight(
            hostFrame: hostFrameInWindow,
            chromeFrame: chromeFrameInWindow
        )
    }

    private func keyboardOverlapHeight(in hostView: UIView?) -> CGFloat {
        guard let hostView, let window = hostView.window else {
            return 0
        }
        guard keyboardFrameInScreen.isNull == false else {
            return 0
        }

        let hostFrameInScreen = hostView.convert(hostView.bounds, to: window.screen.coordinateSpace)
        let overlap = hostFrameInScreen.intersection(keyboardFrameInScreen)
        guard overlap.isNull == false else {
            return 0
        }
        return overlap.height
    }

    private func effectiveAlpha(of view: UIView) -> CGFloat {
        var alpha = view.alpha
        var currentSuperview = view.superview

        while let superview = currentSuperview {
            if superview.isHidden {
                return 0
            }
            alpha *= superview.alpha
            currentSuperview = superview.superview
        }

        return alpha
    }
}
#endif

@MainActor
final class BrowserViewportWebView: WKWebView {
    weak var viewportCoordinator: BrowserViewportCoordinator?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        viewportCoordinator?.webViewHierarchyDidChange()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        viewportCoordinator?.webViewHierarchyDidChange()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        viewportCoordinator?.webViewSafeAreaInsetsDidChange()
    }
}
#elseif canImport(AppKit)
import AppKit
typealias BrowserPlatformColor = NSColor
#endif

private let logger = Logger(
    subsystem: "Monocly",
    category: "BrowserTabStore"
)

enum BrowserHistoryDirection {
    case back
    case forward
}

struct BrowserHistoryMenuItem {
    let backForwardListItem: WKBackForwardListItem
    let title: String
    let subtitle: String
    let direction: BrowserHistoryDirection
}

private enum BrowserTabStoreSPI {
    private static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }

    // browsingContextController
    static let browsingContextControllerSelector = NSSelectorFromString(
        deobfuscate(["Controller", "Context", "browsing"])
    )
    // backForwardList
    static let backForwardListSelector = NSSelectorFromString(
        deobfuscate(["List", "Forward", "back"])
    )
    // goToBackForwardListItem:
    static let goToBackForwardListItemSelector = NSSelectorFromString(
        deobfuscate([":", "Item", "List", "Forward", "Back", "To", "go"])
    )
    // _setHistoryDelegate:
    static let setHistoryDelegateSelector = NSSelectorFromString(
        deobfuscate([":", "Delegate", "History", "_set"])
    )
    static let maximumHistoryMenuItemCount = 20
}

@MainActor
@Observable final class BrowserTabStore: NSObject {
    let id: UUID
    let webView: WKWebView
    private let initialURL: URL

    var canGoBack = false
    var canGoForward = false
    var estimatedProgress: Double = .zero
    var isLoading = false
    var currentURL: URL?
    var underPageBackgroundColor: BrowserPlatformColor?
    var webContentTerminationCount = 0
    var lastWebContentTerminationDate: Date?
    var lastWebContentTerminationURL: URL?
    var lastNavigationErrorDescription: String?
    var didCommitNavigationCount = 0
    var didFinishNavigationCount = 0
    var pageTitle: String?
    var createdAt: Date
    var lastUsedAt: Date

#if canImport(UIKit)
    private var refreshControl: UIRefreshControl?
#endif

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var hasLoadedInitialRequest = false
    @ObservationIgnored private var isHoldingRestoredTitle: Bool
    @ObservationIgnored private var restoredInteractionState: Data?
    @ObservationIgnored var onStateChanged: (() -> Void)?

    var isShowingProgress: Bool {
        isLoading && estimatedProgress < 1.0
    }

    var displayTitle: String {
        if let pageTitle, pageTitle.isEmpty == false {
            return pageTitle
        }
        if let host = currentURL?.host(), host.isEmpty == false {
            return host
        }
        if let currentURL {
            if currentURL.isFileURL {
                return currentURL.lastPathComponent
            }
            return currentURL.absoluteString
        }
        return "Monocly"
    }

    var persistedURL: URL {
        currentURL ?? webView.url ?? initialURL
    }

    var interactionStateData: Data? {
        restoredInteractionState ?? (webView.interactionState as? Data)
    }

    init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        restoredInteractionState: Data? = nil,
        automaticallyLoadsInitialRequest: Bool = true
    ) {
        self.id = id
        initialURL = url
        currentURL = url
        pageTitle = title
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        isHoldingRestoredTitle = title?.isEmpty == false
        self.restoredInteractionState = restoredInteractionState

        let configuration = WKWebViewConfiguration()
#if canImport(UIKit)
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsInlineMediaPlayback = true
#endif
        configuration.allowsAirPlayForMediaPlayback = true

#if canImport(UIKit)
        webView = BrowserViewportWebView(frame: .zero, configuration: configuration)
#if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .always
#endif
#else
        webView = WKWebView(frame: .zero, configuration: configuration)
#endif
        webView.isInspectable = true
#if canImport(UIKit)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"
#else
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
#endif
        webView.allowsBackForwardNavigationGestures = true

        super.init()
#if canImport(UIKit)
        configureRefreshControl()
#endif

        webView.navigationDelegate = self
        webView.uiDelegate = self
        configureHistoryDelegateIfAvailable()

        setObservers()
        if automaticallyLoadsInitialRequest {
            loadInitialRequestIfNeeded()
        }
    }

    func goBack() {
        guard webView.canGoBack else {
            return
        }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else {
            return
        }
        webView.goForward()
    }

    func go(to item: WKBackForwardListItem) {
        guard spiGoToHistoryItem(item) == false else {
            return
        }
        webView.go(to: item)
    }

    func load(url: URL) {
        restoredInteractionState = nil
        isHoldingRestoredTitle = false
        pageTitle = nil
        currentURL = url
        hasLoadedInitialRequest = true
        webView.load(URLRequest(url: url))
        notifyStateChanged()
    }

    func backHistoryItems(limit: Int = BrowserTabStoreSPI.maximumHistoryMenuItemCount) -> [BrowserHistoryMenuItem] {
        historyItems(direction: .back, limit: limit)
    }

    func forwardHistoryItems(limit: Int = BrowserTabStoreSPI.maximumHistoryMenuItemCount) -> [BrowserHistoryMenuItem] {
        historyItems(direction: .forward, limit: limit)
    }

    func loadInitialRequestIfNeeded() {
        guard hasLoadedInitialRequest == false else {
            return
        }

        hasLoadedInitialRequest = true
        webView.load(URLRequest(url: initialURL))
        if let restoredInteractionState {
            webView.interactionState = restoredInteractionState
            self.restoredInteractionState = nil
        }
        notifyStateChanged()
    }

    func markSelected(at date: Date = Date()) {
        lastUsedAt = date
        loadInitialRequestIfNeeded()
        notifyStateChanged()
    }

    func snapshot(stateFileName: String) -> BrowserTabSnapshot {
        BrowserTabSnapshot(
            id: id,
            url: persistedURL,
            title: pageTitle,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            stateFileName: stateFileName
        )
    }

    private func setObservers() {
        cancellables.removeAll()

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self else {
                    return
                }
                self.estimatedProgress = progress
                self.notifyStateChanged()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.url, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self else {
                    return
                }
                self.syncCurrentURL(url)
                self.notifyStateChanged()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.title, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self else {
                    return
                }
                guard let title else {
                    if self.isHoldingRestoredTitle == false {
                        self.pageTitle = nil
                    }
                    self.notifyStateChanged()
                    return
                }
                self.pageTitle = title
                self.isHoldingRestoredTitle = false
                self.notifyStateChanged()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoForward in
                guard let self else {
                    return
                }
                self.canGoForward = canGoForward
                self.notifyStateChanged()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoBack in
                guard let self else {
                    return
                }
                self.canGoBack = canGoBack
                self.notifyStateChanged()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.underPageBackgroundColor, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] underPageBackgroundColor in
                guard let self else {
                    return
                }
                self.underPageBackgroundColor = underPageBackgroundColor
                self.notifyStateChanged()
            }
            .store(in: &cancellables)
    }

    private func syncNavigationState(
        from webView: WKWebView,
        clearsNavigationError: Bool = false
    ) {
        isLoading = webView.isLoading
        estimatedProgress = webView.estimatedProgress
        lastUsedAt = Date()
        syncCurrentURL(webView.url)
        if clearsNavigationError {
            lastNavigationErrorDescription = nil
        }
        invalidateHistoryIfNeeded()
        notifyStateChanged()
    }

    private func syncCurrentURL(_ url: URL?) {
        currentURL = url
    }

    private func isBenignNavigationCancellation(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func invalidateHistoryIfNeeded() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    private func historyItems(direction: BrowserHistoryDirection, limit: Int) -> [BrowserHistoryMenuItem] {
        spiHistoryItems(direction: direction, limit: limit).map { item in
            BrowserHistoryMenuItem(
                backForwardListItem: item,
                title: historyTitle(for: item),
                subtitle: item.url.absoluteString,
                direction: direction
            )
        }
    }

    private func historyTitle(for item: WKBackForwardListItem) -> String {
        if let title = item.title, title.isEmpty == false {
            return title
        }
        if let host = item.url.host(), host.isEmpty == false {
            return host
        }
        return item.url.absoluteString
    }

    private func spiHistoryItems(direction: BrowserHistoryDirection, limit: Int) -> [WKBackForwardListItem] {
        let clampedLimit = max(0, min(limit, BrowserTabStoreSPI.maximumHistoryMenuItemCount))
        guard clampedLimit > 0 else {
            return []
        }

        let backForwardList = spiBackForwardList() ?? webView.backForwardList
        let step = direction == .back ? -1 : 1

        var items: [WKBackForwardListItem] = []
        var offset = step
        while items.count < clampedLimit, let item = backForwardList.item(at: offset) {
            items.append(item)
            offset += step
        }
        return items
    }

    private func spiBrowsingContextController() -> NSObject? {
        guard webView.responds(to: BrowserTabStoreSPI.browsingContextControllerSelector),
              let browsingContextController = webView.perform(BrowserTabStoreSPI.browsingContextControllerSelector)?
                .takeUnretainedValue() as? NSObject else {
            return nil
        }
        return browsingContextController
    }

    private func spiBackForwardList() -> WKBackForwardList? {
        guard let browsingContextController = spiBrowsingContextController(),
              browsingContextController.responds(to: BrowserTabStoreSPI.backForwardListSelector),
              let backForwardList = browsingContextController.perform(BrowserTabStoreSPI.backForwardListSelector)?
                .takeUnretainedValue() as? WKBackForwardList else {
            return nil
        }
        return backForwardList
    }

    private func spiGoToHistoryItem(_ item: WKBackForwardListItem) -> Bool {
        guard let browsingContextController = spiBrowsingContextController(),
              browsingContextController.responds(to: BrowserTabStoreSPI.goToBackForwardListItemSelector) else {
            return false
        }
        browsingContextController.perform(BrowserTabStoreSPI.goToBackForwardListItemSelector, with: item)
        return true
    }

    private func configureHistoryDelegateIfAvailable() {
        guard webView.responds(to: BrowserTabStoreSPI.setHistoryDelegateSelector) else {
            return
        }
        webView.perform(BrowserTabStoreSPI.setHistoryDelegateSelector, with: self)
    }

#if canImport(UIKit)
    private func configureRefreshControl() {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
        webView.scrollView.refreshControl = control
        refreshControl = control
    }

    @objc private func handleRefreshControl() {
        webView.reload()
    }

    private func endRefreshingIfNeeded() {
        guard let refreshControl, refreshControl.isRefreshing else {
            return
        }
        refreshControl.endRefreshing()
    }
#endif
}

extension BrowserTabStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
#if canImport(AppKit)
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           navigationAction.targetFrame?.isMainFrame != false {
            webView.load(URLRequest(url: url))
            return .cancel
        }
#endif
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        estimatedProgress = .zero
        notifyStateChanged()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        didCommitNavigationCount += 1
        syncNavigationState(from: webView, clearsNavigationError: true)
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        return (.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError navigationError: Error) {
        logger.debug("\(#function) provisional navigation failed")
        if isBenignNavigationCancellation(navigationError) {
#if canImport(UIKit)
            endRefreshingIfNeeded()
#endif
            syncNavigationState(from: webView)
            return
        }
        lastNavigationErrorDescription = navigationError.localizedDescription
#if canImport(UIKit)
        endRefreshingIfNeeded()
#endif
        syncNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError navigationError: Error) {
        logger.debug("\(#function) navigation failed")
        if isBenignNavigationCancellation(navigationError) {
#if canImport(UIKit)
            endRefreshingIfNeeded()
#endif
            syncNavigationState(from: webView)
            return
        }
        lastNavigationErrorDescription = navigationError.localizedDescription
#if canImport(UIKit)
        endRefreshingIfNeeded()
#endif
        syncNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        logger.debug("\(#function) server redirect for provisional navigation")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.debug("\(#function) web content process terminated")
        isLoading = false
        webContentTerminationCount += 1
        lastWebContentTerminationDate = Date()
        lastWebContentTerminationURL = webView.url
        invalidateHistoryIfNeeded()
        notifyStateChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishNavigationCount += 1
        if webView.title == nil {
            isHoldingRestoredTitle = false
            pageTitle = nil
        }
#if canImport(UIKit)
        endRefreshingIfNeeded()
#endif
        syncNavigationState(from: webView, clearsNavigationError: true)
    }
}

extension BrowserTabStore {
    @objc(_webView:backForwardListItemAdded:removed:)
    func _webView(
        _ webView: WKWebView!,
        backForwardListItemAdded itemAdded: WKBackForwardListItem!,
        removed itemsRemoved: [WKBackForwardListItem]!
    ) {
        invalidateHistoryIfNeeded()
        notifyStateChanged()
    }

    @objc(_webView:didNavigateWithNavigationData:)
    func _webView(_ webView: WKWebView!, didNavigateWith navigationData: NSObject!) {
        invalidateHistoryIfNeeded()
        notifyStateChanged()
    }

    @objc(_webView:didUpdateHistoryTitle:forURL:)
    func _webView(_ webView: WKWebView!, didUpdateHistoryTitle title: String!, forURL url: URL!) {
        invalidateHistoryIfNeeded()
        notifyStateChanged()
    }
}

extension BrowserTabStore: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
            return nil
        }
        logger.debug("\(#function) handle new window in existing webView: \(url.absoluteString, privacy: .public)")
        webView.load(URLRequest(url: url))
        return nil
    }

#if canImport(UIKit)
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void
    ) {
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak webView] suggestedActions in
            guard let linkURL = elementInfo.linkURL else {
                return UIMenu(title: "", children: suggestedActions)
            }

            let openInAppAction = UIAction(
                title: String(localized: "monocly.context.open_in_monocly", bundle: .main),
                image: UIImage(systemName: "safari")
            ) { _ in
                guard let webView else {
                    return
                }
                logger.debug("Open link in-app from context menu: \(linkURL.absoluteString, privacy: .public)")
                webView.load(URLRequest(url: linkURL))
            }

            return UIMenu(title: "", children: [openInAppAction] + suggestedActions)
        }

        completionHandler(configuration)
    }
#endif

    func webViewDidClose(_ webView: WKWebView) {
        logger.debug("\(#function) WebView closed")
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        logger.debug("\(#function) JavaScript alert: \(message, privacy: .public)")
        await presentJavaScriptAlert(message: message, webView: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        logger.debug("\(#function) JavaScript confirm: \(message, privacy: .public)")
        return await presentJavaScriptConfirm(message: message, webView: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        logger.debug("\(#function) JavaScript prompt: \(prompt, privacy: .public)")
        return await presentJavaScriptPrompt(prompt: prompt, defaultText: defaultText, webView: webView)
    }
}

private extension BrowserTabStore {
#if canImport(UIKit)
    @MainActor
    func presentJavaScriptAlert(message: String, webView: WKWebView) async {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("alert presenter not found; ignoring alert")
            return
        }
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
                continuation.resume()
            })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    func presentJavaScriptConfirm(message: String, webView: WKWebView) async -> Bool {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("confirm presenter not found; denying")
            return false
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "common.cancel", bundle: .main), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    func presentJavaScriptPrompt(prompt: String, defaultText: String?, webView: WKWebView) async -> String? {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("prompt presenter not found; denying")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = defaultText
            }
            alert.addAction(UIAlertAction(title: String(localized: "common.cancel", bundle: .main), style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
                continuation.resume(returning: alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }

    func findPresenter(for webView: WKWebView) -> UIViewController? {
        var responder: UIResponder? = webView
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return webView.window?.rootViewController
    }
#else
    @MainActor
    func presentJavaScriptAlert(message: String, webView: WKWebView) async {
        guard let window = webView.window else {
            logger.error("alert window not found; ignoring alert")
            return
        }
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in
                continuation.resume()
            }
        }
    }

    @MainActor
    func presentJavaScriptConfirm(message: String, webView: WKWebView) async -> Bool {
        guard let window = webView.window else {
            logger.error("confirm window not found; denying")
            return false
        }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    @MainActor
    func presentJavaScriptPrompt(prompt: String, defaultText: String?, webView: WKWebView) async -> String? {
        guard let window = webView.window else {
            logger.error("prompt window not found; denying")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let textField = NSTextField(string: defaultText ?? "")
            alert.accessoryView = textField
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: textField.stringValue)
            }
        }
    }
#endif
}
