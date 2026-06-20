import Combine
import Foundation
import Observation
import OSLog
import UIKit
import WebKit

let logger = Logger(
    subsystem: "Monocly",
    category: "BrowserTab"
)

@MainActor
@Observable final class BrowserTab: NSObject {
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
    private(set) var persistenceRevision = 0

    private var refreshControl: UIRefreshControl?

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var hasLoadedInitialRequest = false
    @ObservationIgnored private(set) var initialRequestLoadCount = 0
    @ObservationIgnored var isHoldingRestoredTitle: Bool
    @ObservationIgnored private var restoredInteractionState: Data?
    @ObservationIgnored var isRestoringInteractionStateNavigation = false
    @ObservationIgnored private var canSaveWebViewInteractionState = true
    @ObservationIgnored private var titleObservationAppliedCount = 0
    @ObservationIgnored private var titleObservationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored static var didInstallSameDocumentNavigationDelegateMethod = false

    var isShowingProgress: Bool {
        isLoading
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
        _ = persistenceRevision
        if let restoredInteractionState {
            return restoredInteractionState
        }
        guard canSaveWebViewInteractionState else {
            return nil
        }
        return webView.interactionState as? Data
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
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true

        webView = BrowserViewportWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.isInspectable = true
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"
        webView.allowsBackForwardNavigationGestures = true

        super.init()
        configureRefreshControl()

        Self.installSameDocumentNavigationDelegateMethodIfNeeded()
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
        if webView.goBack() != nil {
            markWebViewInteractionStatePendingNavigation()
            beginLoadingProgress()
        }
    }

    func goForward() {
        guard webView.canGoForward else {
            return
        }
        if webView.goForward() != nil {
            markWebViewInteractionStatePendingNavigation()
            beginLoadingProgress()
        }
    }

    func go(to item: WKBackForwardListItem) {
        if spiGoToHistoryItem(item) {
            markWebViewInteractionStatePendingNavigation()
            beginLoadingProgress()
            return
        }
        if webView.go(to: item) != nil {
            markWebViewInteractionStatePendingNavigation()
            beginLoadingProgress()
        }
    }

    func load(url: URL) {
        restoredInteractionState = nil
        isRestoringInteractionStateNavigation = false
        markWebViewInteractionStatePendingNavigation()
        isHoldingRestoredTitle = false
        pageTitle = nil
        currentURL = url
        hasLoadedInitialRequest = true
        if webView.load(URLRequest(url: url)) != nil {
            beginLoadingProgress()
        }
    }

    func loadInitialRequestIfNeeded() {
        guard hasLoadedInitialRequest == false else {
            return
        }

        hasLoadedInitialRequest = true
        if let restoredInteractionState {
            isRestoringInteractionStateNavigation = true
            webView.interactionState = restoredInteractionState
            self.restoredInteractionState = nil
            notePersistenceChanged()
            if webView.isLoading == false {
                isRestoringInteractionStateNavigation = false
            }
            canSaveWebViewInteractionState = true
        } else {
            initialRequestLoadCount += 1
            markWebViewInteractionStatePendingNavigation()
            if webView.load(URLRequest(url: initialURL)) != nil {
                beginLoadingProgress()
            }
        }
    }

    func markSelected(at date: Date = Date()) {
        lastUsedAt = date
        loadInitialRequestIfNeeded()
    }

    func snapshot() -> BrowserSession.TabSnapshot {
        BrowserSession.TabSnapshot(
            id: id,
            url: persistedURL,
            title: pageTitle,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
    }

    func waitUntilTitleObservationApplied(atLeast count: Int = 1) async {
        guard titleObservationAppliedCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            titleObservationWaiters.append((count, continuation))
        }
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
            }
            .store(in: &cancellables)

        webView.publisher(for: \.url, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self else {
                    return
                }
                self.syncCurrentURL(url)
            }
            .store(in: &cancellables)

        webView.publisher(for: \.title, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self else {
                    return
                }
                guard let title, title.isEmpty == false else {
                    if self.isHoldingRestoredTitle == false {
                        self.pageTitle = nil
                    }
                    self.noteTitleObservationApplied()
                    return
                }
                self.pageTitle = title
                self.isHoldingRestoredTitle = false
                self.noteTitleObservationApplied()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoForward in
                guard let self else {
                    return
                }
                self.canGoForward = canGoForward
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoBack in
                guard let self else {
                    return
                }
                self.canGoBack = canGoBack
            }
            .store(in: &cancellables)

        webView.publisher(for: \.underPageBackgroundColor, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] underPageBackgroundColor in
                guard let self else {
                    return
                }
                self.underPageBackgroundColor = underPageBackgroundColor
            }
            .store(in: &cancellables)
    }

    func syncNavigationState(
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
    }

    private func syncCurrentURL(_ url: URL?) {
        currentURL = url
    }

    func markWebViewInteractionStatePendingNavigation() {
        guard canSaveWebViewInteractionState else {
            return
        }
        canSaveWebViewInteractionState = false
        notePersistenceChanged()
    }

    func beginLoadingProgress() {
        isLoading = true
        estimatedProgress = .zero
    }

    func markWebViewInteractionStateSynchronized() {
        guard canSaveWebViewInteractionState == false else {
            return
        }
        canSaveWebViewInteractionState = true
        notePersistenceChanged()
    }

    func markWebViewInteractionStateSynchronizedIfNavigationSettled() {
        guard webView.isLoading == false else {
            return
        }
        markWebViewInteractionStateSynchronized()
    }

    func clearRestoredInteractionStateNavigationIfNeeded() {
        isRestoringInteractionStateNavigation = false
    }

    func invalidateHistoryIfNeeded() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func notePersistenceChanged() {
        persistenceRevision &+= 1
    }

    private func noteTitleObservationApplied() {
        titleObservationAppliedCount += 1
        var remainingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in titleObservationWaiters {
            if titleObservationAppliedCount >= count {
                continuation.resume()
            } else {
                remainingWaiters.append((count, continuation))
            }
        }
        titleObservationWaiters = remainingWaiters
    }

    private func configureRefreshControl() {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
        webView.scrollView.refreshControl = control
        refreshControl = control
    }

    @objc private func handleRefreshControl() {
        markWebViewInteractionStatePendingNavigation()
        if webView.reload() != nil {
            beginLoadingProgress()
        }
    }

    func endRefreshingIfNeeded() {
        guard let refreshControl, refreshControl.isRefreshing else {
            return
        }
        refreshControl.endRefreshing()
    }
}
