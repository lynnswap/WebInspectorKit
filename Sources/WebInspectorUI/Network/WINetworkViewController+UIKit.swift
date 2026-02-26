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
    private let compactRootViewController: WINetworkCompactViewController
    private let compactNavigationController: UINavigationController
    private let regularHostViewController: WINetworkRegularSplitViewController

    private weak var activeHostViewController: UIViewController?
    private var activeHostKind: HostKind?
    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    public var onHostNavigationItemsDidChange: (() -> Void)?

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

    public init(inspector: WINetworkModel) {
        self.inspector = inspector
        self.compactRootViewController = WINetworkCompactViewController(inspector: inspector)
        let compactNavigationController = UINavigationController(rootViewController: compactRootViewController)
        wiApplyClearNavigationBarStyle(to: compactNavigationController)
        self.compactNavigationController = compactNavigationController
        self.regularHostViewController = WINetworkRegularSplitViewController(inspector: inspector)

        super.init(nibName: nil, bundle: nil)

        self.regularHostViewController.onHostNavigationItemsDidChange = { [weak self] in
            guard let self, self.activeHostKind == .regular else {
                return
            }
            self.onHostNavigationItemsDidChange?()
        }
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

    public func applyHostNavigationItems(to navigationItem: UINavigationItem) {
        if activeHostKind == nil {
            rebuildHost(force: true)
        }

        guard activeHostKind == .regular else {
            clearHostManagedNavigationControls(from: navigationItem)
            return
        }
        regularHostViewController.applyHostNavigationItems(to: navigationItem)
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
        onHostNavigationItemsDidChange?()
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

    private func clearHostManagedNavigationControls(from navigationItem: UINavigationItem) {
        navigationItem.titleView = nil
        navigationItem.searchController = nil
        navigationItem.additionalOverflowItems = nil
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems(nil, animated: false)
    }
}

@MainActor
private final class WINetworkRegularSplitViewController: UISplitViewController, UISplitViewControllerDelegate, WIHostNavigationItemProvider {
    private let inspector: WINetworkModel
    private var hasStartedObservingInspector = false
    private let selectionUpdateCoalescer = UIUpdateCoalescer()
    private var observedSelectedEntryID: UUID?
    private var selectedEntryObservationHandles: [ObservationHandle] = []
    private var selectedEntryBodyObservationHandles: [ObservationHandle] = []

    private let listPaneViewController: WINetworkListViewController
    private let detailViewController: WINetworkDetailViewController
    private let detailNavigationController: UINavigationController
    private let hiddenPrimaryViewController: UIViewController
    private var hasAppliedInitialRegularColumnWidth = false
    var onHostNavigationItemsDidChange: (() -> Void)?

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        self.listPaneViewController = WINetworkListViewController(inspector: inspector)
        let detailViewController = WINetworkDetailViewController(
            inspector: inspector,
            showsNavigationControls: false
        )
        self.detailViewController = detailViewController
        let detailNavigationController = UINavigationController(rootViewController: detailViewController)
        wiApplyClearNavigationBarStyle(to: detailNavigationController)
        self.detailNavigationController = detailNavigationController
        let hiddenPrimary = UIViewController()
        hiddenPrimary.view.backgroundColor = .clear
        self.hiddenPrimaryViewController = hiddenPrimary

        super.init(style: .tripleColumn)

        delegate = self
        title = nil
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary

        setViewController(hiddenPrimaryViewController, for: .primary)
        setViewController(listPaneViewController, for: .supplementary)
        setViewController(detailNavigationController, for: .secondary)

        minimumPrimaryColumnWidth = 0
        maximumPrimaryColumnWidth = 1
        preferredPrimaryColumnWidthFraction = 0
        minimumSupplementaryColumnWidth = 280
        maximumSupplementaryColumnWidth = .greatestFiniteMagnitude
        preferredSupplementaryColumnWidthFraction = 0.42

        listPaneViewController.onSelectEntry = { [weak self] entry in
            guard let self else {
                return
            }
            inspector.selectEntry(id: entry?.id)
            syncDetailSelection()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInitialRegularColumnWidthIfNeeded()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObservingInspectorIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyInitialRegularColumnWidthIfNeeded()
        showSupplementaryColumnIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        listPaneViewController.applyNavigationItems(to: navigationItem)
        syncDetailSelection()
    }

    private func startObservingInspectorIfNeeded() {
        guard hasStartedObservingInspector == false else {
            return
        }
        hasStartedObservingInspector = true
        inspector.observeTask(
            [
                \.selectedEntry,
                \.searchText,
                \.activeResourceFilters,
                \.effectiveResourceFilters,
                \.sortDescriptors
            ]
        ) { [weak self] in
            self?.synchronizeSelectedEntryObservation()
            self?.scheduleDetailSelectionSync()
            self?.onHostNavigationItemsDidChange?()
        }
        inspector.store.observeTask(
            [
                \.entries
            ]
        ) { [weak self] in
            self?.synchronizeSelectedEntryObservation()
            self?.scheduleDetailSelectionSync()
            self?.onHostNavigationItemsDidChange?()
        }
        synchronizeSelectedEntryObservation()
    }

    private func scheduleDetailSelectionSync() {
        selectionUpdateCoalescer.schedule { [weak self] in
            self?.syncDetailSelection()
        }
    }

    private func synchronizeSelectedEntryObservation() {
        let selectedEntryID = inspector.selectedEntry?.id
        guard observedSelectedEntryID != selectedEntryID else {
            return
        }
        observedSelectedEntryID = selectedEntryID
        clearSelectedEntryObservationHandles()
        clearSelectedEntryBodyObservationHandles()

        guard let selectedEntry = inspector.selectedEntry else {
            return
        }

        selectedEntryObservationHandles.append(
            selectedEntry.observeTask(
                [
                    \.url,
                    \.method,
                    \.statusCode,
                    \.statusText,
                    \.mimeType,
                    \.fileTypeLabel,
                    \.requestHeaders,
                    \.responseHeaders,
                    \.duration,
                    \.encodedBodyLength,
                    \.decodedBodyLength,
                    \.errorDescription,
                    \.phase,
                    \.requestBody,
                    \.responseBody
                ]
            ) { [weak self, weak selectedEntry] in
                self?.scheduleDetailSelectionSync()
                guard let self, let selectedEntry else {
                    return
                }
                self.synchronizeSelectedEntryBodyObservation(for: selectedEntry)
            }
        )
        synchronizeSelectedEntryBodyObservation(for: selectedEntry)
    }

    private func synchronizeSelectedEntryBodyObservation(for selectedEntry: NetworkEntry) {
        clearSelectedEntryBodyObservationHandles()
        if let requestBody = selectedEntry.requestBody {
            selectedEntryBodyObservationHandles.append(
                requestBody.observeTask(
                    [
                        \.kind,
                        \.preview,
                        \.full,
                        \.size,
                        \.isBase64Encoded,
                        \.isTruncated,
                        \.summary,
                        \.reference,
                        \.formEntries,
                        \.fetchState
                    ]
                ) { [weak self] in
                    self?.scheduleDetailSelectionSync()
                }
            )
        }
        if let responseBody = selectedEntry.responseBody {
            selectedEntryBodyObservationHandles.append(
                responseBody.observeTask(
                    [
                        \.kind,
                        \.preview,
                        \.full,
                        \.size,
                        \.isBase64Encoded,
                        \.isTruncated,
                        \.summary,
                        \.reference,
                        \.formEntries,
                        \.fetchState
                    ]
                ) { [weak self] in
                    self?.scheduleDetailSelectionSync()
                }
            )
        }
    }

    private func clearSelectedEntryObservationHandles() {
        for handle in selectedEntryObservationHandles {
            handle.cancel()
        }
        selectedEntryObservationHandles.removeAll()
    }

    private func clearSelectedEntryBodyObservationHandles() {
        for handle in selectedEntryBodyObservationHandles {
            handle.cancel()
        }
        selectedEntryBodyObservationHandles.removeAll()
    }

    private func syncDetailSelection() {
        let resolvedSelection = NetworkListSelectionPolicy.resolvedSelection(
            current: inspector.selectedEntry,
            entries: inspector.displayEntries,
            whenMissing: .firstEntry
        )
        if inspector.selectedEntry?.id != resolvedSelection?.id {
            inspector.selectEntry(id: resolvedSelection?.id)
        }

        detailViewController.display(inspector.selectedEntry, hasEntries: !inspector.store.entries.isEmpty)
        listPaneViewController.selectEntry(with: inspector.selectedEntry?.id)
        listPaneViewController.setMissingSelectionBehavior(.firstEntry)

        if inspector.selectedEntry == nil {
            showSupplementaryColumnIfNeeded()
        }
    }

    private func showSupplementaryColumnIfNeeded() {
        guard traitCollection.horizontalSizeClass != .compact else {
            return
        }
        guard viewController(for: .supplementary) != nil else {
            return
        }
        show(.supplementary)
    }

    private func applyInitialRegularColumnWidthIfNeeded() {
        guard traitCollection.horizontalSizeClass != .compact else {
            hasAppliedInitialRegularColumnWidth = false
            return
        }
        guard hasAppliedInitialRegularColumnWidth == false else {
            return
        }
        guard view.bounds.width > 0 else {
            return
        }
        preferredSupplementaryColumnWidth = max(minimumSupplementaryColumnWidth, view.bounds.width * 0.42)
        hasAppliedInitialRegularColumnWidth = true
    }

    func applyHostNavigationItems(to navigationItem: UINavigationItem) {
        listPaneViewController.applyNavigationItems(to: navigationItem)
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        if inspector.selectedEntry == nil {
            return .supplementary
        }
        return proposedTopColumn
    }
}

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


#endif
