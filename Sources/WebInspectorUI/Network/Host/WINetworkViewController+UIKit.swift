import Foundation
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
public final class WINetworkViewController: UIViewController, WIHostNavigationItemProvider, WICompactNavigationHosting {
    private enum HostKind {
        case compact
        case regular
    }

    private let inspector: WINetworkModel
    private let queryModel: WINetworkQueryModel
    private let compactRootViewController: WINetworkCompactViewController
    private let compactNavigationController: UINavigationController
    private let regularHostViewController: WINetworkRegularSplitViewController

    private weak var activeHostViewController: UIViewController?
    private var activeHostKind: HostKind?
    public let hostNavigationState = WIHostNavigationState()
    private var regularHostNavigationObservationHandles: [ObservationHandle] = []
    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    var activeHostKindForTesting: String? {
        switch activeHostKind {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return nil
        }
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHostViewController
    }

    var providesCompactNavigationController: Bool {
        true
    }

    public convenience init(inspector: WINetworkModel) {
        self.init(
            inspector: inspector,
            queryModel: WINetworkQueryModel(inspector: inspector)
        )
    }

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        self.queryModel = queryModel
        self.compactRootViewController = WINetworkCompactViewController(
            inspector: inspector,
            queryModel: queryModel
        )
        let compactNavigationController = UINavigationController(rootViewController: compactRootViewController)
        wiApplyClearNavigationBarStyle(to: compactNavigationController)
        self.compactNavigationController = compactNavigationController
        self.regularHostViewController = WINetworkRegularSplitViewController(
            inspector: inspector,
            queryModel: queryModel
        )

        super.init(nibName: nil, bundle: nil)
        bindRegularHostNavigationState()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        rebuildHost(force: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.rebuildHost()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildHost()
    }

    private func rebuildHost(force: Bool = false) {
        let targetHostKind: HostKind = effectiveHorizontalSizeClass == .compact ? .compact : .regular
        guard force || activeHostKind != targetHostKind else {
            return
        }
        activeHostKind = targetHostKind

        let nextHost: UIViewController
        switch targetHostKind {
        case .compact:
            nextHost = compactNavigationController
        case .regular:
            nextHost = regularHostViewController
        }
        installHost(nextHost)
        syncHostNavigationStateFromActiveHost()
    }

    private func installHost(_ host: UIViewController) {
        if let current = activeHostViewController, current !== host {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
            activeHostViewController = nil
        }

        guard activeHostViewController !== host else {
            return
        }

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        activeHostViewController = host
    }

    private func bindRegularHostNavigationState() {
        let regularState = regularHostViewController.hostNavigationState
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.searchController) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.preferredSearchBarPlacement) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.hidesSearchBarWhenScrolling) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.leftBarButtonItems) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.rightBarButtonItems) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.additionalOverflowItems) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
    }

    private func syncHostNavigationStateFromActiveHost() {
        guard activeHostKind == .regular else {
            hostNavigationState.clearManagedItems()
            return
        }
        let regularState = regularHostViewController.hostNavigationState
        hostNavigationState.searchController = regularState.searchController
        hostNavigationState.preferredSearchBarPlacement = regularState.preferredSearchBarPlacement
        hostNavigationState.hidesSearchBarWhenScrolling = regularState.hidesSearchBarWhenScrolling
        hostNavigationState.leftBarButtonItems = regularState.leftBarButtonItems
        hostNavigationState.rightBarButtonItems = regularState.rightBarButtonItems
        hostNavigationState.additionalOverflowItems = regularState.additionalOverflowItems
    }
}
@MainActor
func networkStatusColor(for severity: NetworkStatusSeverity) -> UIColor {
    switch severity {
    case .success:
        return .systemGreen
    case .notice:
        return .systemYellow
    case .warning:
        return .systemOrange
    case .error:
        return .systemRed
    case .neutral:
        return .secondaryLabel
    }
}
@MainActor
func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
    let headerValue: String?
    switch body.role {
    case .request:
        headerValue = entry.requestHeaders["content-type"]
    case .response:
        headerValue = entry.responseHeaders["content-type"] ?? entry.mimeType
    }
    if let headerValue, !headerValue.isEmpty {
        let trimmed = headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        return trimmed ?? headerValue
    }
    return body.kind.rawValue.uppercased()
}
@MainActor
func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
    if let size = body.size {
        return size
    }
    switch body.role {
    case .request:
        return entry.requestBodyBytesSent
    case .response:
        return entry.decodedBodyLength ?? entry.encodedBodyLength
    }
}

func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

func decodedBodyText(from body: NetworkBody) -> String? {
    guard let rawText = body.full ?? body.preview, !rawText.isEmpty else {
        return nil
    }
    guard body.isBase64Encoded else {
        return rawText
    }
    guard let data = Data(base64Encoded: rawText) else {
        return rawText
    }
    return String(data: data, encoding: .utf8) ?? rawText
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Root (UIKit)") {
    WIUIKitPreviewContainer {
        WINetworkViewController(inspector: WINetworkPreviewFixtures.makeInspector(mode: .root))
    }
}

#Preview("Network Root Long Title (UIKit)") {
    WIUIKitPreviewContainer {
        WINetworkViewController(inspector: WINetworkPreviewFixtures.makeInspector(mode: .rootLongTitle))
    }
}
#endif


#endif
