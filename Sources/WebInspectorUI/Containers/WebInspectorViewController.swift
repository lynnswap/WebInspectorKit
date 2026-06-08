#if canImport(UIKit)
import ObservationBridge
import WebInspectorCore
import UIKit
import WebKit

@MainActor
public final class WebInspectorViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public let session: WebInspectorSession
    private var drawsBackgroundStorage = true
    private var followsInspectedPageAppearanceStorage = false
    private var appliedInspectedPageInterfaceStyle: UIUserInterfaceStyle?
    private let observationScope = ObservationScope()

    public var followsInspectedPageAppearance: Bool {
        get { followsInspectedPageAppearanceStorage }
        set { setFollowsInspectedPageAppearance(newValue) }
    }

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
        bindInterfaceAppearance()
    }

    public convenience init(tabs: [WebInspectorTab]) {
        self.init(session: WebInspectorSession(tabs: tabs))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
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

    public func attach(to webView: WKWebView) async throws {
        try await session.attach(to: webView)
    }

    public func detach() async {
        await session.detach()
    }

    private var effectiveHostKind: HostKind {
        (horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass) == .compact ? .compact : .regular
    }

    private func handleHorizontalSizeClassChange() {
        rebuildLayout()
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    private func bindInterfaceAppearance() {
        observationScope.observe(session.interface) { [weak self] _, interface in
            self?.applyPreferredInterfaceStyle(interface.preferredInterfaceStyle)
        }
    }

    private func applyPreferredInterfaceStyle(_ style: UIUserInterfaceStyle) {
        guard followsInspectedPageAppearanceStorage else {
            return
        }

        if overrideUserInterfaceStyle != style {
            overrideUserInterfaceStyle = style
            appliedInspectedPageInterfaceStyle = style
        } else if appliedInspectedPageInterfaceStyle != nil {
            appliedInspectedPageInterfaceStyle = style
        }
    }

    private func setFollowsInspectedPageAppearance(_ followsInspectedPageAppearance: Bool) {
        guard followsInspectedPageAppearanceStorage != followsInspectedPageAppearance else {
            return
        }
        followsInspectedPageAppearanceStorage = followsInspectedPageAppearance
        guard followsInspectedPageAppearance else {
            clearAppliedInspectedPageInterfaceStyle()
            return
        }
        applyPreferredInterfaceStyle(session.interface.preferredInterfaceStyle)
    }

    private func clearAppliedInspectedPageInterfaceStyle() {
        defer {
            appliedInspectedPageInterfaceStyle = nil
        }
        guard let appliedInspectedPageInterfaceStyle,
              overrideUserInterfaceStyle == appliedInspectedPageInterfaceStyle else {
            return
        }
        overrideUserInterfaceStyle = .unspecified
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
}

#endif
