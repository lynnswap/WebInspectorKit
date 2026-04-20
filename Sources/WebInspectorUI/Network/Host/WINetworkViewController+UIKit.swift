import Foundation
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
public final class WINetworkViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let compactHostViewController: WINetworkCompactViewController
    private let listPaneViewController: WINetworkListViewController
    private let listNavigationController: UINavigationController
    private let detailViewController: WINetworkDetailViewController
    private let detailNavigationController: UINavigationController

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            traitOverrides.horizontalSizeClass = horizontalSizeClassOverrideForTesting ?? .unspecified
        }
    }

    var activeHostKindForTesting: String? {
        let sizeClass = horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
        return sizeClass == .compact ? "compact" : "regular"
    }

    var activeHostViewControllerForTesting: UIViewController? {
        self
    }

    var splitViewControllerForTesting: UISplitViewController {
        self
    }

    var primaryColumnViewControllerForTesting: UIViewController? {
        viewController(for: .primary)
    }

    var secondaryColumnViewControllerForTesting: UIViewController? {
        viewController(for: .secondary)
    }

    var compactColumnViewControllerForTesting: UIViewController? {
        viewController(for: .compact)
    }

    public convenience init(inspector: WINetworkModel) {
        self.init(
            inspector: inspector,
            queryModel: WINetworkQueryModel(inspector: inspector)
        )
    }

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.compactHostViewController = WINetworkCompactViewController(
            inspector: inspector,
            queryModel: queryModel
        )
        let listPaneViewController = WINetworkListViewController(inspector: inspector, queryModel: queryModel)
        self.listPaneViewController = listPaneViewController
        let listNavigationController = UINavigationController(rootViewController: listPaneViewController)
        wiApplyClearNavigationBarStyle(to: listNavigationController)
        listNavigationController.navigationBar.prefersLargeTitles = false
        self.listNavigationController = listNavigationController
        let detailViewController = WINetworkDetailViewController(
            inspector: inspector,
            showsNavigationControls: false
        )
        self.detailViewController = detailViewController
        let detailNavigationController = UINavigationController(rootViewController: detailViewController)
        wiApplyClearNavigationBarStyle(to: detailNavigationController)
        detailNavigationController.setNavigationBarHidden(true, animated: false)
        self.detailNavigationController = detailNavigationController

        super.init(style: .doubleColumn)

        delegate = self
        title = nil
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary

        setViewController(listNavigationController, for: .primary)
        setViewController(detailNavigationController, for: .secondary)
        setViewController(compactHostViewController, for: .compact)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.listPaneViewController.applyListColumnNavigationItemsForRegularLayout()
            self.updateNavigationItemState()
        }
        listPaneViewController.applyListColumnNavigationItemsForRegularLayout()
        updateNavigationItemState()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        listPaneViewController.applyListColumnNavigationItemsForRegularLayout()
        updateNavigationItemState()
    }

    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        listPaneViewController.applyListColumnNavigationItemsForRegularLayout()
        updateNavigationItemState()
    }

    private func updateNavigationItemState() {
        if let hostNavigationItem = parent?.navigationItem,
           parent?.navigationController != nil {
            clearNavigationItemState(on: navigationItem)
            applyNavigationItemState(to: hostNavigationItem)
            return
        }

        applyNavigationItemState(to: navigationItem)
    }

    private func applyNavigationItemState(to navigationItem: UINavigationItem) {
        navigationItem.searchController = nil
        navigationItem.preferredSearchBarPlacement = .automatic
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems([listPaneViewController.filterNavigationItem], animated: false)
        navigationItem.additionalOverflowItems = listPaneViewController.hostOverflowItemsForRegularNavigation
    }

    private func clearNavigationItemState(on navigationItem: UINavigationItem) {
        navigationItem.searchController = nil
        navigationItem.preferredSearchBarPlacement = .automatic
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems(nil, animated: false)
        navigationItem.additionalOverflowItems = nil
    }

    public func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        _ = splitViewController
        _ = proposedTopColumn
        return .compact
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
