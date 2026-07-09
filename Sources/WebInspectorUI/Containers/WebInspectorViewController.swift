#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorUIBase

@MainActor
private final class WebInspectorRootPresentationLifecycleCoordinator {
    private var didFinishCurrentPresentation = false
    private var presentationGeneration: UInt64 = 0

    func beginPresentation() {
        didFinishCurrentPresentation = false
        presentationGeneration &+= 1
    }

    func finishIfNeeded(_ finish: (_ generation: UInt64) -> Void) {
        guard didFinishCurrentPresentation == false else {
            return
        }
        didFinishCurrentPresentation = true
        finish(presentationGeneration)
    }

    func isCurrentPresentation(_ generation: UInt64) -> Bool {
        presentationGeneration == generation
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

/// A UIKit view controller that presents the built-in WebInspectorKit UI.
///
/// Create an instance, attach it to a `WKWebView`, and present it from your app
/// UI. The controller adapts between compact tab presentation and regular split
/// presentation.
///
/// Example:
///
/// ```swift
/// let inspector = WebInspectorViewController()
/// inspector.modalPresentationStyle = .pageSheet
///
/// Task { @MainActor in
///     try await inspector.attach(to: webView)
///     present(inspector, animated: true)
/// }
/// ```
@MainActor
public final class WebInspectorViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    /// The inspection session backing the view controller.
    public let session: WebInspectorSession

    /// A Boolean value indicating whether the controller detaches its session
    /// after the root presentation ends.
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

    /// Controls whether the inspector draws its own background.
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

    /// Creates a view controller backed by an inspection session.
    public init(session: WebInspectorSession = WebInspectorSession()) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        webInspectorSetDrawsBackgroundTraitOverride(drawsBackgroundStorage)
    }

    /// Creates a view controller with a custom tab set.
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
        rebuildLayout(forceHostReplacement: activeHost == nil)
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

    /// Attaches the backing session to a web view.
    public func attach(to webView: WKWebView) async throws {
        try await session.attach(to: webView)
    }

    /// Detaches the backing session.
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
        presentationLifecycleCoordinator.finishIfNeeded { [session, automaticallyDetachesOnDismiss, presentationLifecycleCoordinator] generation in
            removeActiveHost()
            Task { @MainActor in
                // A re-presentation can begin before this deferred retirement
                // runs; retiring then would tear down content the new
                // presentation has already built.
                guard presentationLifecycleCoordinator.isCurrentPresentation(generation) else {
                    return
                }
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
        removeActiveHost()

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

    private func removeActiveHost() {
        guard let activeHost else {
            activeHostKind = nil
            return
        }
        activeHost.willMove(toParent: nil)
        activeHost.view.removeFromSuperview()
        activeHost.removeFromParent()
        self.activeHost = nil
        activeHostKind = nil
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
