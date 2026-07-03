#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorCore
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
private final class WebInspectorRootPresentationLifecycleCoordinator {
    private var didFinishCurrentPresentation = false

    func beginPresentation() {
        didFinishCurrentPresentation = false
    }

    func finishIfNeeded(_ finish: () -> Void) {
        guard didFinishCurrentPresentation == false else {
            return
        }
        didFinishCurrentPresentation = true
        finish()
    }

    #if DEBUG
    var hasFinishedCurrentPresentationForTesting: Bool {
        didFinishCurrentPresentation
    }
    #endif
}

private final class WebInspectorPresentationHostWindowObserverView: UIView {
    var onDetachedFromWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else {
            return
        }
        onDetachedFromWindow?()
    }
}

@MainActor
public final class WebInspectorViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public let session: WebInspectorSession
    public var automaticallyDetachesOnDismiss = true
    private var drawsBackgroundStorage = true
    private let presentationLifecycleCoordinator = WebInspectorRootPresentationLifecycleCoordinator()
    private lazy var presentationHostWindowObserver: WebInspectorPresentationHostWindowObserverView = {
        let view = WebInspectorPresentationHostWindowObserverView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.onDetachedFromWindow = { [weak self] in
            self?.presentationHostWindowDidDetach()
        }
        return view
    }()
    private weak var observedPresentationHostView: UIView?
    private var suppressPresentationHostWindowObserver = false

    @available(iOS 26.0, *)
    public var drawsBackground: Bool {
        get { drawsBackgroundStorage }
        set { setDrawsBackground(newValue) }
    }

    private var activeHost: UIViewController?
    private var activeHostKind: HostKind?
    package var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            rebuildLayout(forceHostReplacement: true)
        }
    }

    public init(session: WebInspectorSession = WebInspectorSession()) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        webInspectorSetDrawsBackgroundTraitOverride(drawsBackgroundStorage)
    }

    public convenience init(tabs: [WebInspectorTab]) {
        self.init(session: WebInspectorSession(tabs: tabs))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        rebuildLayout(forceHostReplacement: true)
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.handleHorizontalSizeClassChange()
        }
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationLifecycleCoordinator.beginPresentation()
        installPresentationHostWindowObserverIfNeeded()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installPresentationHostWindowObserverIfNeeded()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isTerminalRootDisappearance,
              transitionCoordinator?.isCancelled != true else {
            return
        }
        finishRootPresentationLifecycle()
    }

    public override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        let wasPresentedAsRoot = isRootPresentationActive
        super.dismiss(animated: flag) { [weak self] in
            guard let self else {
                completion?()
                return
            }
            if wasPresentedAsRoot,
               self.viewIfLoaded?.window == nil {
                self.finishRootPresentationLifecycle()
            }
            completion?()
        }
        if wasPresentedAsRoot,
           flag == false {
            finishRootPresentationLifecycle()
        }
    }

    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil,
              isViewLoaded,
              view.window == nil else {
            return
        }
        finishRootPresentationLifecycle()
    }

    package func attachPresentation(
        to webView: WKWebView,
        perform attach: @MainActor (InspectorSession, WKWebView) async throws -> WebInspectorContext?
    ) async throws {
        try await session.attachPresentation(to: webView, perform: attach)
    }

    @_disfavoredOverload
    public func attach(to webView: WKWebView) async throws {
        try await session.attach(to: webView)
    }

    public func detach() async {
        await session.detach()
    }

    private var effectiveHostKind: HostKind {
        (horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass) == .compact ? .compact : .regular
    }

    private var isTerminalRootDisappearance: Bool {
        isBeingDismissed
            || isMovingFromParent
            || navigationController?.isBeingDismissed == true
            || navigationController?.isMovingFromParent == true
            || parent?.isBeingDismissed == true
            || parent?.isMovingFromParent == true
    }

    private var isRootPresentationActive: Bool {
        presentingViewController != nil
            || presentationController?.presentedViewController === self
            || navigationController?.presentingViewController != nil
            || navigationController?.presentationController?.presentedViewController === navigationController
    }

    private func finishRootPresentationLifecycle() {
        presentationLifecycleCoordinator.finishIfNeeded { [session, automaticallyDetachesOnDismiss] in
            Task { @MainActor [session] in
                await session.retireRootPresentation(detach: automaticallyDetachesOnDismiss)
            }
        }
    }

    private func installPresentationHostWindowObserverIfNeeded() {
        guard let hostView = navigationController?.view ?? viewIfLoaded,
              hostView.window != nil,
              observedPresentationHostView !== hostView else {
            return
        }

        suppressPresentationHostWindowObserver = true
        presentationHostWindowObserver.removeFromSuperview()
        suppressPresentationHostWindowObserver = false

        observedPresentationHostView = hostView
        hostView.addSubview(presentationHostWindowObserver)
    }

    private func presentationHostWindowDidDetach() {
        guard suppressPresentationHostWindowObserver == false else {
            return
        }
        finishRootPresentationLifecycle()
    }

    private func handleHorizontalSizeClassChange() {
        rebuildLayout()
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    private func setDrawsBackground(_ drawsBackground: Bool) {
        guard drawsBackgroundStorage != drawsBackground else {
            return
        }
        drawsBackgroundStorage = drawsBackground
        webInspectorSetDrawsBackgroundTraitOverride(drawsBackground)
        activeHost?.webInspectorSetDrawsBackgroundTraitOverride(drawsBackground)
        if isViewLoaded {
            applyBackgroundFromTraits()
        }
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        let targetHostKind = effectiveHostKind
        guard forceHostReplacement || activeHostKind != targetHostKind else {
            return
        }
        installHost(of: targetHostKind)
    }

    private func installHost(of kind: HostKind) {
        if let activeHost {
            activeHost.willMove(toParent: nil)
            activeHost.view.removeFromSuperview()
            activeHost.removeFromParent()
        }
        activeHost = nil
        activeHostKind = nil

        let host: UIViewController
        switch kind {
        case .compact:
            host = CompactTabBarController(session: session)
        case .regular:
            host = RegularTabContentViewController(session: session)
        }
        host.webInspectorSetDrawsBackgroundTraitOverride(drawsBackgroundStorage)

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        activeHost = host
        activeHostKind = kind
    }

    package var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    #if DEBUG
    package func finishRootPresentationLifecycleForTesting(cancelled: Bool = false) {
        guard cancelled == false else {
            return
        }
        finishRootPresentationLifecycle()
    }

    package var hasFinishedRootPresentationLifecycleForTesting: Bool {
        presentationLifecycleCoordinator.hasFinishedCurrentPresentationForTesting
    }
    #endif
}

#endif
