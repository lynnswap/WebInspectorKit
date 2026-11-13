#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
private final class WebInspectorRootPresentationLifecycleCoordinator {
    #if DEBUG
    private struct RetirementTaskCompletionWaiter {
        var baselineCount: UInt64
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }
    #endif

    private var didFinishCurrentPresentation = false
    private var presentationGeneration: UInt64 = 0
    #if DEBUG
    private var retirementTaskCompletionCount: UInt64 = 0
    private var retirementTaskCompletionWaiters: [UInt64: RetirementTaskCompletionWaiter] = [:]
    private var nextRetirementTaskCompletionWaiterID: UInt64 = 0
    #endif

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

    var retirementTaskCompletionCountForTesting: UInt64 {
        retirementTaskCompletionCount
    }

    func waitForRetirementTaskCompletionForTesting(
        after baselineCount: UInt64,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        if retirementTaskCompletionCount > baselineCount {
            return true
        }

        return await withCheckedContinuation { continuation in
            let waiterID = nextRetirementTaskCompletionWaiterID
            nextRetirementTaskCompletionWaiterID &+= 1
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveRetirementTaskCompletionWaiterForTesting(id: waiterID, result: false)
            }
            retirementTaskCompletionWaiters[waiterID] = RetirementTaskCompletionWaiter(
                baselineCount: baselineCount,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            if retirementTaskCompletionCount > baselineCount {
                resolveRetirementTaskCompletionWaiterForTesting(id: waiterID, result: true)
            }
        }
    }

    func recordRetirementTaskCompletionForTesting() {
        retirementTaskCompletionCount &+= 1
        let completedWaiterIDs = retirementTaskCompletionWaiters.compactMap { id, waiter in
            retirementTaskCompletionCount > waiter.baselineCount ? id : nil
        }
        for waiterID in completedWaiterIDs {
            resolveRetirementTaskCompletionWaiterForTesting(id: waiterID, result: true)
        }
    }

    private func resolveRetirementTaskCompletionWaiterForTesting(
        id: UInt64,
        result: Bool
    ) {
        guard let waiter = retirementTaskCompletionWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
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
/// Create an instance, attach its ``inspector`` to a `WKWebView`, and present
/// it from your app UI. The controller adapts between compact tab presentation
/// and regular split presentation.
///
/// ```swift
/// let controller = WebInspectorViewController()
/// controller.modalPresentationStyle = .pageSheet
/// controller.inspector.attach(to: webView)
/// present(controller, animated: true)
/// ```
///
/// To inspect another web view, attach the inspector again. To keep inspecting
/// while the UI is not on screen, keep the ``WebInspector`` and create the
/// view controller from it each time; the selected tab stays with the
/// inspector.
@MainActor
public final class WebInspectorViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    /// The inspector that the view controller presents.
    public let inspector: WebInspector
    let session: WebInspectorSession
    private let presentationContentStore: PresentationContentStore
    private let rootPresentationID = UUID()

    /// A Boolean value indicating whether the controller detaches its
    /// inspector after the root presentation ends.
    ///
    /// When several view controllers present one inspector, it is detached
    /// after the last of them is dismissed.
    public var automaticallyDetachesOnDismiss = true
    private var drawsBackgroundStorage = true
    private let presentationLifecycleCoordinator = WebInspectorRootPresentationLifecycleCoordinator()
    #if DEBUG
    private(set) var rootPresentationRetirementTaskForTesting: Task<Void, Never>?
    private var deinitHandlerForTesting: (@MainActor () -> Void)?
    #endif
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
    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            rebuildLayout(forceHostReplacement: true)
        }
    }

    /// Creates a view controller that presents an inspector.
    ///
    /// The tabs and the selected tab belong to the inspector's presentation:
    /// view controllers that present the same inspector share them, and they
    /// stay with the inspector between presentations.
    ///
    /// - Parameters:
    ///   - inspector: The inspector to present. The default is a new,
    ///     detached inspector.
    ///   - tabs: The tabs to show. Pass `nil` to keep the tabs that the
    ///     inspector was last presented with, which are the DOM and Network
    ///     tabs for an inspector that has not been presented.
    public convenience init(
        inspector: WebInspector = WebInspector(),
        tabs: [WebInspectorTab]? = nil
    ) {
        let session = WebInspectorSession.session(for: inspector)
        if let tabs {
            session.interface.setTabs(tabs)
        }
        self.init(inspector: inspector, session: session)
    }

    /// Creates a view controller for a session that keeps its own inspector.
    convenience init(session: WebInspectorSession) {
        guard let inspector = session.inspector else {
            preconditionFailure("A session outlives its inspector only while a view controller keeps both.")
        }
        self.init(inspector: inspector, session: session)
    }

    private init(inspector: WebInspector, session: WebInspectorSession) {
        self.inspector = inspector
        self.session = session
        self.presentationContentStore = PresentationContentStore()
        super.init(nibName: nil, bundle: nil)
        webInspectorSetDrawsBackgroundTraitOverride(drawsBackgroundStorage)
        WebInspectorSession.prepareRuntimesIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        session.abandonRootPresentation(
            id: rootPresentationID,
            detach: automaticallyDetachesOnDismiss
        )
        #if DEBUG
        deinitHandlerForTesting?()
        #endif
    }

    /// Configures the inspector layout after the view loads.
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

    /// Starts presentation lifecycle tracking before the view appears.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationLifecycleCoordinator.beginPresentation()
        session.beginRootPresentation(id: rootPresentationID)
        rebuildLayout(forceHostReplacement: activeHost == nil)
        installPresentationHostWindowObserverIfNeeded()
    }

    /// Installs presentation lifecycle observation after the view appears.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installPresentationHostWindowObserverIfNeeded()
    }

    /// Finishes root presentation lifecycle tracking after terminal disappearance.
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isTerminalRootDisappearance,
              transitionCoordinator?.isCancelled != true else {
            return
        }
        finishRootPresentationLifecycle()
    }

    /// Dismisses the inspector and retires the root presentation when needed.
    public override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        let wasPresentedAsRoot = isRootPresentationActive
        if wasPresentedAsRoot {
            session.beginRootPresentation(id: rootPresentationID)
        }
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

    /// Retires presentation state when the controller is removed from its parent.
    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil,
              isViewLoaded,
              view.window == nil else {
            return
        }
        finishRootPresentationLifecycle()
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
        presentationLifecycleCoordinator.finishIfNeeded { [
            session,
            presentationContentStore,
            rootPresentationID,
            automaticallyDetachesOnDismiss,
            presentationLifecycleCoordinator,
        ] generation in
            removeActiveHost()
            let task = Task { @MainActor in
                defer {
                    #if DEBUG
                    presentationLifecycleCoordinator.recordRetirementTaskCompletionForTesting()
                    #endif
                }
                // A re-presentation can begin before this deferred retirement
                // runs; retiring then would tear down content the new
                // presentation has already built.
                guard presentationLifecycleCoordinator.isCurrentPresentation(generation) else {
                    return
                }
                presentationContentStore.clear()
                await session.retireRootPresentation(
                    id: rootPresentationID,
                    detach: automaticallyDetachesOnDismiss
                )
            }
            #if DEBUG
            rootPresentationRetirementTaskForTesting = task
            #endif
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
            host = CompactTabBarController(
                session: session,
                contentStore: presentationContentStore
            )
        case .regular:
            host = RegularTabContentViewController(
                session: session,
                contentStore: presentationContentStore
            )
        }
        host.webInspectorSetDrawsBackgroundTraitOverride(drawsBackgroundStorage)

        addChild(host)
        // Resize the UIKit host with its parent so a sheet's initial layout
        // does not leave the floating tab bar at its pre-presentation height.
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
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

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    #if DEBUG
    func setDeinitHandlerForTesting(_ handler: @escaping @MainActor () -> Void) {
        deinitHandlerForTesting = handler
    }

    var presentationContentStoreForTesting: PresentationContentStore {
        presentationContentStore
    }

    func finishRootPresentationLifecycleForTesting() {
        guard presentationLifecycleCoordinator.hasFinishedCurrentPresentationForTesting == false else {
            return
        }
        session.beginRootPresentation(id: rootPresentationID)
        finishRootPresentationLifecycle()
    }

    var hasFinishedRootPresentationLifecycleForTesting: Bool {
        presentationLifecycleCoordinator.hasFinishedCurrentPresentationForTesting
    }

    var rootPresentationRetirementTaskCompletionCountForTesting: UInt64 {
        presentationLifecycleCoordinator.retirementTaskCompletionCountForTesting
    }

    func waitForRootPresentationRetirementTaskCompletionForTesting(
        after baselineCount: UInt64
    ) async -> Bool {
        await presentationLifecycleCoordinator.waitForRetirementTaskCompletionForTesting(after: baselineCount)
    }
    #endif
}

#endif
