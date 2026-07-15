#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorUIBase

@MainActor
private final class WebInspectorRootPresentationLifecycleCoordinator {
    private var didFinishCurrentPresentation = false
    private var presentationGeneration: UInt64 = 0
    private var retirementTasks: [UUID: Task<Void, Never>] = [:]
    #if DEBUG
    private var retirementTaskCompletionCount: UInt64 = 0
    #endif

    func beginPresentation() {
        didFinishCurrentPresentation = false
        presentationGeneration &+= 1
    }

    func finishIfNeeded(
        prepare: () -> Void,
        retirement: @escaping @MainActor (_ generation: UInt64) async -> Void
    ) {
        guard didFinishCurrentPresentation == false else {
            return
        }
        didFinishCurrentPresentation = true
        let generation = presentationGeneration
        prepare()
        let taskID = UUID()
        let task = Task { @MainActor [self] in
            await retirement(generation)
            finishRetirementTask(id: taskID)
        }
        retirementTasks[taskID] = task
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
        after baselineCount: UInt64
    ) async -> Bool {
        if retirementTaskCompletionCount > baselineCount {
            return true
        }
        let runningTasks = Array(retirementTasks.values)
        guard runningTasks.isEmpty == false else {
            return false
        }
        for task in runningTasks {
            await task.value
        }
        return retirementTaskCompletionCount > baselineCount
    }
    #endif

    private func finishRetirementTask(id: UUID) {
        retirementTasks[id] = nil
        #if DEBUG
        retirementTaskCompletionCount &+= 1
        #endif
    }
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

    private enum SessionOwnership {
        case owned
        case borrowed
    }

    /// The inspection session backing the view controller.
    public let session: WebInspectorSession
    private let sessionOwnership: SessionOwnership
    private let interface: InterfaceModel
    private let presentationContentStore: PresentationContentStore
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

    /// Creates a view controller that owns its inspection session.
    ///
    /// A terminal presentation dismissal closes the owned session after the
    /// presentation resources have retired.
    public convenience init(
        catalog: WebInspectorTabCatalog = .standard
    ) {
        self.init(
            session: WebInspectorSession(),
            catalog: catalog,
            sessionOwnership: .owned
        )
    }

    /// Creates a view controller that borrows an app-owned inspection session.
    ///
    /// A terminal presentation dismissal retires only presentation resources.
    /// The caller remains responsible for detaching or closing `session`.
    public convenience init(
        session: WebInspectorSession,
        catalog: WebInspectorTabCatalog = .standard
    ) {
        self.init(
            session: session,
            catalog: catalog,
            sessionOwnership: .borrowed
        )
    }

    private init(
        session: WebInspectorSession,
        catalog: WebInspectorTabCatalog,
        sessionOwnership: SessionOwnership
    ) {
        self.session = session
        self.sessionOwnership = sessionOwnership
        self.interface = InterfaceModel(catalog: catalog)
        self.presentationContentStore = PresentationContentStore(
            context: WebInspectorTab.Context(session: session)
        )
        super.init(nibName: nil, bundle: nil)
        webInspectorSetDrawsBackgroundTraitOverride(drawsBackgroundStorage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
        let closesSession: Bool = switch sessionOwnership {
        case .owned: true
        case .borrowed: false
        }
        presentationLifecycleCoordinator.finishIfNeeded(
            prepare: { removeActiveHost() }
        ) { [
            session,
            presentationContentStore,
            presentationLifecycleCoordinator,
            closesSession,
        ] generation in
            // A re-presentation can begin before this deferred retirement
            // runs; retiring then would tear down content the new
            // presentation has already built.
            guard presentationLifecycleCoordinator.isCurrentPresentation(generation) else {
                return
            }
            await presentationContentStore.clear()
            // Resource retirement may suspend long enough for this root to
            // begin a new presentation. Never detach that newer lifetime.
            guard presentationLifecycleCoordinator.isCurrentPresentation(generation) else {
                return
            }
            guard closesSession else {
                return
            }
            await session.close()
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
                interface: interface,
                contentStore: presentationContentStore
            )
        case .regular:
            host = RegularTabContentViewController(
                session: session,
                interface: interface,
                contentStore: presentationContentStore
            )
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

    package var interfaceForTesting: InterfaceModel { interface }

    #if DEBUG
    package var presentationContentStoreForTesting: PresentationContentStore {
        presentationContentStore
    }

    package func finishRootPresentationLifecycleForTesting(cancelled: Bool = false) {
        guard cancelled == false else {
            return
        }
        finishRootPresentationLifecycle()
    }

    package var hasFinishedRootPresentationLifecycleForTesting: Bool {
        presentationLifecycleCoordinator.hasFinishedCurrentPresentationForTesting
    }

    package var rootPresentationRetirementTaskCompletionCountForTesting: UInt64 {
        presentationLifecycleCoordinator.retirementTaskCompletionCountForTesting
    }

    package func waitForRootPresentationRetirementTaskCompletionForTesting(
        after baselineCount: UInt64
    ) async -> Bool {
        await presentationLifecycleCoordinator.waitForRetirementTaskCompletionForTesting(after: baselineCount)
    }
    #endif
}

#endif
