import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
private enum WINetworkHeaderRole {
    case request
    case response
}

@MainActor
private enum WINetworkDetailSectionIdentifier: Int, Hashable, CaseIterable {
    case overview
    case requestHeaders
    case requestBody
    case responseHeaders
    case responseBody
    case error
}

@MainActor
private enum WINetworkDetailRowIdentifier: Hashable {
    case overview
    case requestHeader(Int)
    case requestHeadersEmpty
    case requestBody
    case responseHeader(Int)
    case responseHeadersEmpty
    case responseBody
    case error
}

@MainActor
final class WINetworkDetailViewController: NSViewController, NSTableViewDelegate {
    private enum ViewIdentifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("WINetworkDetail.Column")
        static let overviewCell = NSUserInterfaceItemIdentifier("WINetworkDetail.OverviewCell")
        static let headerFieldCell = NSUserInterfaceItemIdentifier("WINetworkDetail.HeaderFieldCell")
        static let emptyHeadersCell = NSUserInterfaceItemIdentifier("WINetworkDetail.EmptyHeadersCell")
        static let bodyCell = NSUserInterfaceItemIdentifier("WINetworkDetail.BodyCell")
        static let errorCell = NSUserInterfaceItemIdentifier("WINetworkDetail.ErrorCell")
        static let sectionHeader = NSUserInterfaceItemIdentifier("WINetworkDetail.SectionHeader")
    }

    private let inspector: WINetworkModel
    private var selectedEntryStructureObservationHandles: Set<ObservationHandle> = []

    private let scrollView = NSScrollView()
    private let tableView = NSTableView(frame: .zero)
    private let tableColumn = NSTableColumn(identifier: ViewIdentifier.tableColumn)
    private lazy var dataSource = makeDataSource()
    private let emptyStateView = WINetworkAppKitViewFactory.makeEmptyStateView(
        title: wiLocalized("network.empty.title"),
        description: wiLocalized("network.empty.description")
    )

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var renderedSectionTitlesForTesting: [String] {
        dataSource.snapshot().sectionIdentifiers.map(sectionTitle(for:))
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    var hasVisibleContentForTesting: Bool {
        scrollView.isHidden == false
    }

    var requestBodyButtonForTesting: NSButton? {
        bodyButtonForTesting(role: .request)
    }

    var responseBodyButtonForTesting: NSButton? {
        bodyButtonForTesting(role: .response)
    }

    var presentedBodyPreviewViewControllerForTesting: WINetworkBodyPreviewViewController? {
        presentedViewControllers?.first as? WINetworkBodyPreviewViewController
    }

    func requestHeaderValueForTesting(index: Int) -> String? {
        headerValueForTesting(rowIdentifier: .requestHeader(index))
    }

    func responseHeaderValueForTesting(index: Int) -> String? {
        headerValueForTesting(rowIdentifier: .responseHeader(index))
    }

    func overviewRowHeightForTesting() -> CGFloat? {
        rowHeightForTesting(rowIdentifier: .overview)
    }

    func requestHeaderRowHeightForTesting(index: Int) -> CGFloat? {
        rowHeightForTesting(rowIdentifier: .requestHeader(index))
    }

    func responseHeaderRowHeightForTesting(index: Int) -> CGFloat? {
        rowHeightForTesting(rowIdentifier: .responseHeader(index))
    }

    private func headerValueForTesting(rowIdentifier: WINetworkDetailRowIdentifier) -> String? {
        guard let row = rowForTesting(rowIdentifier: rowIdentifier) else {
            return nil
        }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? WINetworkHeaderFieldTableCellView else {
            return nil
        }
        return cell.valueTextForTesting
    }

    private func rowHeightForTesting(rowIdentifier: WINetworkDetailRowIdentifier) -> CGFloat? {
        guard let row = rowForTesting(rowIdentifier: rowIdentifier) else {
            return nil
        }
        return tableView.rect(ofRow: row).height
    }

    private func rowForTesting(rowIdentifier: WINetworkDetailRowIdentifier) -> Int? {
        guard let row = dataSource.row(forItemIdentifier: rowIdentifier) else {
            return nil
        }
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        return row
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureTableView()
        _ = dataSource
        display(inspector.selectedEntry)
    }

    func display(_ entry: NetworkEntry?) {
        selectedEntryStructureObservationHandles.removeAll()
        if let entry {
            startObservingEntryStructure(entry)
        }
        requestSnapshotUpdate()
        updateVisibility()
    }

    func updateVisibility() {
        let hasEntries = inspector.store.entries.isEmpty == false
        let hasSelection = inspector.selectedEntry != nil
        scrollView.isHidden = hasSelection == false
        emptyStateView.isHidden = hasEntries || hasSelection

        if hasSelection == false {
            if dataSource.snapshot().itemIdentifiers.isEmpty == false {
                requestSnapshotUpdate()
            }
            if let presented = presentedViewControllers?.first {
                dismiss(presented)
            }
        }
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
        scrollView.documentView = tableView

        view.addSubview(scrollView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func configureTableView() {
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = dataSource
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.rowSizeStyle = .default
        tableView.usesAutomaticRowHeights = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.focusRingType = .none
    }

    private func makeDataSource() -> NSTableViewDiffableDataSource<WINetworkDetailSectionIdentifier, WINetworkDetailRowIdentifier> {
        let dataSource = NSTableViewDiffableDataSource<WINetworkDetailSectionIdentifier, WINetworkDetailRowIdentifier>(
            tableView: tableView
        ) { [weak self] tableView, _, _, rowIdentifier in
            guard let self else {
                return NSView()
            }

            switch rowIdentifier {
            case .overview:
                let cell = self.makeOverviewCell(in: tableView)
                cell.configure(inspector: self.inspector) { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .overview)
                }
                return cell
            case .requestHeader(let index):
                let cell = self.makeHeaderFieldCell(in: tableView)
                cell.configure(inspector: self.inspector, role: .request, fieldIndex: index) { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .requestHeader(index))
                }
                return cell
            case .requestHeadersEmpty:
                let cell = self.makeEmptyHeadersCell(in: tableView)
                cell.configure(text: wiLocalized("network.headers.empty", default: "No headers")) { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .requestHeadersEmpty)
                }
                return cell
            case .requestBody:
                let cell = self.makeBodyCell(in: tableView)
                cell.configure(inspector: self.inspector, role: .request, onNeedsLayout: { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .requestBody)
                }) { [weak self] role in
                    self?.showBodyPreview(for: role)
                }
                return cell
            case .responseHeader(let index):
                let cell = self.makeHeaderFieldCell(in: tableView)
                cell.configure(inspector: self.inspector, role: .response, fieldIndex: index) { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .responseHeader(index))
                }
                return cell
            case .responseHeadersEmpty:
                let cell = self.makeEmptyHeadersCell(in: tableView)
                cell.configure(text: wiLocalized("network.headers.empty", default: "No headers")) { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .responseHeadersEmpty)
                }
                return cell
            case .responseBody:
                let cell = self.makeBodyCell(in: tableView)
                cell.configure(inspector: self.inspector, role: .response, onNeedsLayout: { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .responseBody)
                }) { [weak self] role in
                    self?.showBodyPreview(for: role)
                }
                return cell
            case .error:
                let cell = self.makeErrorCell(in: tableView)
                cell.configure(inspector: self.inspector) { [weak self] in
                    self?.handleRowLayoutInvalidation(for: .error)
                }
                return cell
            }
        }

        dataSource.sectionHeaderViewProvider = { [weak self] tableView, _, sectionIdentifier in
            guard let self else {
                return NSView()
            }
            let headerView = self.makeSectionHeaderView(in: tableView)
            headerView.configure(title: self.sectionTitle(for: sectionIdentifier))
            return headerView
        }

        return dataSource
    }

    private func makeOverviewCell(in tableView: NSTableView) -> WINetworkOverviewTableCellView {
        if let cell = tableView.makeView(withIdentifier: ViewIdentifier.overviewCell, owner: nil) as? WINetworkOverviewTableCellView {
            return cell
        }
        let cell = WINetworkOverviewTableCellView(frame: .zero)
        cell.identifier = ViewIdentifier.overviewCell
        return cell
    }

    private func makeHeaderFieldCell(in tableView: NSTableView) -> WINetworkHeaderFieldTableCellView {
        if let cell = tableView.makeView(withIdentifier: ViewIdentifier.headerFieldCell, owner: nil) as? WINetworkHeaderFieldTableCellView {
            return cell
        }
        let cell = WINetworkHeaderFieldTableCellView(frame: .zero)
        cell.identifier = ViewIdentifier.headerFieldCell
        return cell
    }

    private func makeEmptyHeadersCell(in tableView: NSTableView) -> WINetworkEmptyHeadersTableCellView {
        if let cell = tableView.makeView(withIdentifier: ViewIdentifier.emptyHeadersCell, owner: nil) as? WINetworkEmptyHeadersTableCellView {
            return cell
        }
        let cell = WINetworkEmptyHeadersTableCellView(frame: .zero)
        cell.identifier = ViewIdentifier.emptyHeadersCell
        return cell
    }

    private func makeBodyCell(in tableView: NSTableView) -> WINetworkBodyTableCellView {
        if let cell = tableView.makeView(withIdentifier: ViewIdentifier.bodyCell, owner: nil) as? WINetworkBodyTableCellView {
            return cell
        }
        let cell = WINetworkBodyTableCellView(frame: .zero)
        cell.identifier = ViewIdentifier.bodyCell
        return cell
    }

    private func makeErrorCell(in tableView: NSTableView) -> WINetworkErrorTableCellView {
        if let cell = tableView.makeView(withIdentifier: ViewIdentifier.errorCell, owner: nil) as? WINetworkErrorTableCellView {
            return cell
        }
        let cell = WINetworkErrorTableCellView(frame: .zero)
        cell.identifier = ViewIdentifier.errorCell
        return cell
    }

    private func makeSectionHeaderView(in tableView: NSTableView) -> WINetworkDetailSectionHeaderView {
        if let view = tableView.makeView(withIdentifier: ViewIdentifier.sectionHeader, owner: nil) as? WINetworkDetailSectionHeaderView {
            return view
        }
        let view = WINetworkDetailSectionHeaderView(frame: .zero)
        view.identifier = ViewIdentifier.sectionHeader
        return view
    }

    private func startObservingEntryStructure(_ entry: NetworkEntry) {
        entry.observe(
            \.requestHeaders,
            onChange: { [weak self, weak entry] headers in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.handleHeadersChange(role: .request, count: headers.fields.count)
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryStructureObservationHandles)

        entry.observe(
            \.responseHeaders,
            onChange: { [weak self, weak entry] headers in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.handleHeadersChange(role: .response, count: headers.fields.count)
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryStructureObservationHandles)

        entry.observe(
            \.requestBody,
            onChange: { [weak self, weak entry] _ in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.handleBodyChange(role: .request)
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryStructureObservationHandles)

        entry.observe(
            \.responseBody,
            onChange: { [weak self, weak entry] _ in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.handleBodyChange(role: .response)
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryStructureObservationHandles)

        entry.observe(
            \.errorDescription,
            onChange: { [weak self, weak entry] value in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.handleErrorChange(isPresent: value?.isEmpty == false)
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryStructureObservationHandles)
    }

    private func handleHeadersChange(role: WINetworkHeaderRole, count: Int) {
        let section: WINetworkDetailSectionIdentifier = role == .request ? .requestHeaders : .responseHeaders
        let expectedItems: [WINetworkDetailRowIdentifier] = {
            if count == 0 {
                return [role == .request ? .requestHeadersEmpty : .responseHeadersEmpty]
            }
            return (0..<count).map { role == .request ? .requestHeader($0) : .responseHeader($0) }
        }()

        let snapshot = dataSource.snapshot()
        let currentItems = snapshot.itemIdentifiers(inSection: section)
        guard currentItems != expectedItems else {
            return
        }
        requestSnapshotUpdate()
    }

    private func handleBodyChange(role: NetworkBody.Role) {
        guard let entry = inspector.selectedEntry else {
            return
        }

        let section: WINetworkDetailSectionIdentifier = role == .request ? .requestBody : .responseBody
        let item: WINetworkDetailRowIdentifier = role == .request ? .requestBody : .responseBody
        let body: NetworkBody? = role == .request ? entry.requestBody : entry.responseBody

        let snapshot = dataSource.snapshot()
        let hasSection = snapshot.sectionIdentifiers.contains(section)

        if (body != nil) != hasSection {
            requestSnapshotUpdate()
            return
        }

        guard body != nil, hasSection else {
            return
        }

        var reloadingSnapshot = snapshot
        reloadingSnapshot.reloadItems([item])
        dataSource.apply(reloadingSnapshot, animatingDifferences: false)
        handleRowLayoutInvalidation(for: item)
    }

    private func handleErrorChange(isPresent: Bool) {
        let snapshot = dataSource.snapshot()
        let hasSection = snapshot.sectionIdentifiers.contains(.error)

        if isPresent != hasSection {
            requestSnapshotUpdate()
        }
    }

    private func requestSnapshotUpdate() {
        let snapshot = makeSnapshot()
        let currentSnapshot = dataSource.snapshot()

        if currentSnapshot.sectionIdentifiers == snapshot.sectionIdentifiers,
           currentSnapshot.itemIdentifiers == snapshot.itemIdentifiers {
            return
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<WINetworkDetailSectionIdentifier, WINetworkDetailRowIdentifier> {
        var snapshot = NSDiffableDataSourceSnapshot<WINetworkDetailSectionIdentifier, WINetworkDetailRowIdentifier>()
        guard let entry = inspector.selectedEntry else {
            return snapshot
        }

        snapshot.appendSections([.overview])
        snapshot.appendItems([.overview], toSection: .overview)

        snapshot.appendSections([.requestHeaders])
        let requestHeaderItems: [WINetworkDetailRowIdentifier] = entry.requestHeaders.fields.isEmpty
            ? [.requestHeadersEmpty]
            : entry.requestHeaders.fields.indices.map { .requestHeader($0) }
        snapshot.appendItems(requestHeaderItems, toSection: .requestHeaders)

        if entry.requestBody != nil {
            snapshot.appendSections([.requestBody])
            snapshot.appendItems([.requestBody], toSection: .requestBody)
        }

        snapshot.appendSections([.responseHeaders])
        let responseHeaderItems: [WINetworkDetailRowIdentifier] = entry.responseHeaders.fields.isEmpty
            ? [.responseHeadersEmpty]
            : entry.responseHeaders.fields.indices.map { .responseHeader($0) }
        snapshot.appendItems(responseHeaderItems, toSection: .responseHeaders)

        if entry.responseBody != nil {
            snapshot.appendSections([.responseBody])
            snapshot.appendItems([.responseBody], toSection: .responseBody)
        }

        if let errorDescription = entry.errorDescription, errorDescription.isEmpty == false {
            snapshot.appendSections([.error])
            snapshot.appendItems([.error], toSection: .error)
        }

        return snapshot
    }

    private func sectionTitle(for section: WINetworkDetailSectionIdentifier) -> String {
        switch section {
        case .overview:
            return wiLocalized("network.detail.section.overview", default: "Overview")
        case .requestHeaders:
            return wiLocalized("network.section.request", default: "Request")
        case .requestBody:
            return wiLocalized("network.section.body.request", default: "Request Body")
        case .responseHeaders:
            return wiLocalized("network.section.response", default: "Response")
        case .responseBody:
            return wiLocalized("network.section.body.response", default: "Response Body")
        case .error:
            return wiLocalized("network.section.error", default: "Error")
        }
    }

    private func bodyButtonForTesting(role: NetworkBody.Role) -> NSButton? {
        let itemIdentifier: WINetworkDetailRowIdentifier = role == .request ? .requestBody : .responseBody
        guard let row = dataSource.row(forItemIdentifier: itemIdentifier) else {
            return nil
        }
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? WINetworkBodyTableCellView else {
            return nil
        }
        return cell.actionButton
    }

    private func handleRowLayoutInvalidation(for rowIdentifier: WINetworkDetailRowIdentifier) {
        guard let row = dataSource.row(forItemIdentifier: rowIdentifier) else {
            return
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        tableView.needsDisplay = true
    }

    private func showBodyPreview(for role: NetworkBody.Role) {
        guard let entry = inspector.selectedEntry else {
            return
        }

        let body: NetworkBody?
        switch role {
        case .request:
            body = entry.requestBody
        case .response:
            body = entry.responseBody
        }

        guard body != nil else {
            return
        }

        if let presented = presentedViewControllers?.first {
            dismiss(presented)
        }

        presentAsSheet(
            WINetworkBodyPreviewViewController(
                inspector: inspector,
                role: role
            )
        )
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        _ = tableView
        _ = row
        return false
    }
}

@MainActor
private final class WINetworkOverviewTableCellView: NSTableCellView {
    private var inspector: WINetworkModel?
    private var onNeedsLayout: (() -> Void)?
    private var selectionObservationHandles: Set<ObservationHandle> = []
    private var entryObservationHandles: Set<ObservationHandle> = []

    private let metricsStack = NSStackView()
    private let statusMetricView = WINetworkAppKitViewFactory.makeMetricView(symbolName: "circle.fill", text: "")
    private let durationMetricView = WINetworkAppKitViewFactory.makeMetricView(symbolName: "clock", text: "")
    private let encodedMetricView = WINetworkAppKitViewFactory.makeMetricView(symbolName: "arrow.down.to.line", text: "")
    private let urlLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
        lineBreakMode: .byCharWrapping,
        numberOfLines: 4,
        selectable: true
    )
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
    }

    func configure(inspector: WINetworkModel, onNeedsLayout: @escaping () -> Void) {
        self.inspector = inspector
        self.onNeedsLayout = onNeedsLayout
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
        startObservingSelection()
        syncCurrentEntryObservation()
    }

    private func configureHierarchy() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10

        metricsStack.orientation = .horizontal
        metricsStack.alignment = .centerY
        metricsStack.spacing = 12
        metricsStack.addArrangedSubview(statusMetricView)
        metricsStack.addArrangedSubview(durationMetricView)
        metricsStack.addArrangedSubview(encodedMetricView)

        stackView.addArrangedSubview(metricsStack)
        stackView.addArrangedSubview(urlLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            urlLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
    }

    private var statusImageView: NSImageView {
        statusMetricView.arrangedSubviews[0] as! NSImageView
    }

    private var statusLabel: NSTextField {
        statusMetricView.arrangedSubviews[1] as! NSTextField
    }

    private var durationLabel: NSTextField {
        durationMetricView.arrangedSubviews[1] as! NSTextField
    }

    private var encodedLabel: NSTextField {
        encodedMetricView.arrangedSubviews[1] as! NSTextField
    }

    private func startObservingSelection() {
        guard let inspector else {
            applyNoSelection()
            return
        }
        inspector.observe(
            [\.selectedEntry],
            onChange: { [weak self] in
                self?.syncCurrentEntryObservation()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectionObservationHandles)
    }

    private func syncCurrentEntryObservation() {
        entryObservationHandles.removeAll()
        guard let inspector, let entry = inspector.selectedEntry else {
            applyNoSelection()
            return
        }

        entry.observe(
            [\.url, \.statusCode, \.statusText, \.phase, \.duration, \.encodedBodyLength],
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector?.selectedEntry?.id == entry.id else {
                    return
                }
                self.apply(entry: entry)
            },
            isolation: MainActor.shared
        )
        .store(in: &entryObservationHandles)

        apply(entry: entry)
    }

    private func applyNoSelection() {
        statusLabel.stringValue = ""
        statusImageView.contentTintColor = networkStatusColor(for: .neutral)
        urlLabel.stringValue = ""
        applyMetric(durationMetricView, label: durationLabel, text: nil)
        applyMetric(encodedMetricView, label: encodedLabel, text: nil)
        requestLayoutInvalidation()
    }

    private func apply(entry: NetworkEntry) {
        statusLabel.stringValue = entry.statusLabel
        statusImageView.contentTintColor = networkStatusColor(for: entry.statusSeverity)
        urlLabel.stringValue = entry.url
        applyMetric(durationMetricView, label: durationLabel, text: entry.duration.map(entry.durationText(for:)))
        applyMetric(
            encodedMetricView,
            label: encodedLabel,
            text: entry.encodedBodyLength.map(entry.sizeText(for:))
        )
        requestLayoutInvalidation()
    }

    private func applyMetric(_ metricView: NSStackView, label: NSTextField, text: String?) {
        label.stringValue = text ?? ""
        metricView.isHidden = text == nil
    }

    private func requestLayoutInvalidation() {
        needsLayout = true
        onNeedsLayout?()
    }
}

@MainActor
private final class WINetworkHeaderFieldTableCellView: NSTableCellView {
    private var inspector: WINetworkModel?
    private var onNeedsLayout: (() -> Void)?
    private var role: WINetworkHeaderRole = .request
    private var fieldIndex: Int = 0
    private var selectionObservationHandles: Set<ObservationHandle> = []
    private var entryObservationHandles: Set<ObservationHandle> = []

    private let nameLabel = WINetworkAppKitViewFactory.makeSecondaryLabel("")
    private let valueLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
        lineBreakMode: .byCharWrapping,
        numberOfLines: 0,
        selectable: true
    )
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
    }

    var valueTextForTesting: String {
        valueLabel.stringValue
    }

    func configure(
        inspector: WINetworkModel,
        role: WINetworkHeaderRole,
        fieldIndex: Int,
        onNeedsLayout: @escaping () -> Void
    ) {
        self.inspector = inspector
        self.role = role
        self.fieldIndex = fieldIndex
        self.onNeedsLayout = onNeedsLayout
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
        startObservingSelection()
        syncCurrentEntryObservation()
    }

    private func configureHierarchy() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.addArrangedSubview(nameLabel)
        stackView.addArrangedSubview(valueLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            valueLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
    }

    private func startObservingSelection() {
        guard let inspector else {
            apply(field: nil)
            return
        }
        inspector.observe(
            [\.selectedEntry],
            onChange: { [weak self] in
                self?.syncCurrentEntryObservation()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectionObservationHandles)
    }

    private func syncCurrentEntryObservation() {
        entryObservationHandles.removeAll()
        guard let inspector, let entry = inspector.selectedEntry else {
            apply(field: nil)
            return
        }

        let headersKeyPath: KeyPath<NetworkEntry, NetworkHeaders> = role == .request ? \.requestHeaders : \.responseHeaders
        entry.observe(
            headersKeyPath,
            onChange: { [weak self, weak entry] headers in
                guard let self, let entry else {
                    return
                }
                guard self.inspector?.selectedEntry?.id == entry.id else {
                    return
                }
                self.apply(field: headers.fields[safe: self.fieldIndex])
            },
            isolation: MainActor.shared
        )
        .store(in: &entryObservationHandles)

        apply(field: entry[keyPath: headersKeyPath].fields[safe: fieldIndex])
    }

    private func apply(field: NetworkHeaderField?) {
        nameLabel.stringValue = field?.name ?? ""
        valueLabel.stringValue = field?.value ?? ""
        requestLayoutInvalidation()
    }

    private func requestLayoutInvalidation() {
        needsLayout = true
        onNeedsLayout?()
    }
}

@MainActor
private final class WINetworkEmptyHeadersTableCellView: NSTableCellView {
    private let label = WINetworkAppKitViewFactory.makeSecondaryLabel(
        "",
        lineBreakMode: .byWordWrapping
    )
    private var onNeedsLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(text: String, onNeedsLayout: @escaping () -> Void) {
        label.stringValue = text
        self.onNeedsLayout = onNeedsLayout
        onNeedsLayout()
    }
}

@MainActor
private final class WINetworkBodyTableCellView: NSTableCellView {
    let actionButton = NSButton(title: "", target: nil, action: nil)

    private var inspector: WINetworkModel?
    private var role: NetworkBody.Role = .response
    private var onNeedsLayout: (() -> Void)?
    private var onOpenBodyPreview: ((NetworkBody.Role) -> Void)?
    private var selectionObservationHandles: Set<ObservationHandle> = []
    private var entryObservationHandles: Set<ObservationHandle> = []
    private var bodyObservationHandles: Set<ObservationHandle> = []
    private var observedBodyIdentity: ObjectIdentifier?

    private let summaryLabel = WINetworkAppKitViewFactory.makeSecondaryLabel(
        "",
        numberOfLines: 2,
        selectable: true,
        lineBreakMode: .byWordWrapping
    )
    private let previewLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
        color: .secondaryLabelColor,
        lineBreakMode: .byCharWrapping,
        numberOfLines: 6,
        selectable: true
    )
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
        bodyObservationHandles.removeAll()
    }

    func configure(
        inspector: WINetworkModel,
        role: NetworkBody.Role,
        onNeedsLayout: @escaping () -> Void,
        onOpenBodyPreview: @escaping (NetworkBody.Role) -> Void
    ) {
        self.inspector = inspector
        self.role = role
        self.onNeedsLayout = onNeedsLayout
        self.onOpenBodyPreview = onOpenBodyPreview
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
        bodyObservationHandles.removeAll()
        observedBodyIdentity = nil
        startObservingSelection()
        syncCurrentEntryObservation()
    }

    private func configureHierarchy() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10

        actionButton.isBordered = false
        actionButton.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        actionButton.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        actionButton.imagePosition = .imageLeading
        actionButton.contentTintColor = .controlAccentColor
        actionButton.setButtonType(.momentaryPushIn)
        actionButton.alignment = .left
        actionButton.target = self
        actionButton.action = #selector(openPreview)

        stackView.addArrangedSubview(actionButton)
        stackView.addArrangedSubview(summaryLabel)
        stackView.addArrangedSubview(previewLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            summaryLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
    }

    @objc
    private func openPreview() {
        onOpenBodyPreview?(role)
    }

    private func startObservingSelection() {
        guard let inspector else {
            applyNoBody()
            return
        }
        inspector.observe(
            [\.selectedEntry],
            onChange: { [weak self] in
                self?.syncCurrentEntryObservation()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectionObservationHandles)
    }

    private func syncCurrentEntryObservation() {
        entryObservationHandles.removeAll()
        bodyObservationHandles.removeAll()
        observedBodyIdentity = nil

        guard let inspector, let entry = inspector.selectedEntry else {
            applyNoBody()
            return
        }

        let bodyKeyPath: KeyPath<NetworkEntry, NetworkBody?> = role == .request ? \.requestBody : \.responseBody
        let entryKeyPaths: [PartialKeyPath<NetworkEntry>] = [
            bodyKeyPath,
            \.mimeType,
            \.decodedBodyLength,
            \.encodedBodyLength,
            \.requestBodyBytesSent,
            \.requestHeaders,
            \.responseHeaders
        ]

        entry.observe(
            entryKeyPaths,
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector?.selectedEntry?.id == entry.id else {
                    return
                }
                self.updateCurrentBodyObservation(for: entry)
            },
            isolation: MainActor.shared
        )
        .store(in: &entryObservationHandles)

        updateCurrentBodyObservation(for: entry)
    }

    private func updateCurrentBodyObservation(for entry: NetworkEntry) {
        guard let body = body(from: entry) else {
            bodyObservationHandles.removeAll()
            observedBodyIdentity = nil
            applyNoBody()
            return
        }

        let bodyIdentity = ObjectIdentifier(body)
        if observedBodyIdentity == bodyIdentity, bodyObservationHandles.isEmpty == false {
            apply(entry: entry, body: body)
            return
        }

        bodyObservationHandles.removeAll()
        observedBodyIdentity = bodyIdentity
        body.observe(
            [
                \.role,
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
            ],
            onChange: { [weak self, weak entry, weak body] in
                guard let self, let entry, let body else {
                    return
                }
                guard self.inspector?.selectedEntry?.id == entry.id else {
                    return
                }
                guard self.body(from: entry).map(ObjectIdentifier.init) == bodyIdentity else {
                    return
                }
                self.apply(entry: entry, body: body)
            },
            isolation: MainActor.shared
        )
        .store(in: &bodyObservationHandles)

        apply(entry: entry, body: body)
    }

    private func body(from entry: NetworkEntry) -> NetworkBody? {
        switch role {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }

    private func applyNoBody() {
        actionButton.title = wiLocalized("network.body.unavailable", default: "Body unavailable")
        summaryLabel.stringValue = ""
        summaryLabel.isHidden = true
        previewLabel.stringValue = wiLocalized("network.body.unavailable", default: "Body unavailable")
        requestLayoutInvalidation()
    }

    private func apply(entry: NetworkEntry, body: NetworkBody) {
        actionButton.title = networkDetailBodyPrimaryText(entry: entry, body: body)
        let summary = body.summary ?? ""
        summaryLabel.stringValue = summary
        summaryLabel.isHidden = summary.isEmpty
        previewLabel.stringValue = networkDetailBodySecondaryText(body)
        requestLayoutInvalidation()
    }

    private func requestLayoutInvalidation() {
        needsLayout = true
        onNeedsLayout?()
    }
}

@MainActor
private final class WINetworkErrorTableCellView: NSTableCellView {
    private var inspector: WINetworkModel?
    private var onNeedsLayout: (() -> Void)?
    private var selectionObservationHandles: Set<ObservationHandle> = []
    private var entryObservationHandles: Set<ObservationHandle> = []

    private let errorLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize),
        color: .systemOrange,
        lineBreakMode: .byWordWrapping,
        numberOfLines: 0,
        selectable: true
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
    }

    func configure(inspector: WINetworkModel, onNeedsLayout: @escaping () -> Void) {
        self.inspector = inspector
        self.onNeedsLayout = onNeedsLayout
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
        startObservingSelection()
        syncCurrentEntryObservation()
    }

    private func startObservingSelection() {
        guard let inspector else {
            apply(errorDescription: nil)
            return
        }
        inspector.observe(
            [\.selectedEntry],
            onChange: { [weak self] in
                self?.syncCurrentEntryObservation()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectionObservationHandles)
    }

    private func syncCurrentEntryObservation() {
        entryObservationHandles.removeAll()
        guard let inspector, let entry = inspector.selectedEntry else {
            apply(errorDescription: nil)
            return
        }

        entry.observe(
            \.errorDescription,
            onChange: { [weak self, weak entry] value in
                guard let self, let entry else {
                    return
                }
                guard self.inspector?.selectedEntry?.id == entry.id else {
                    return
                }
                self.apply(errorDescription: value)
            },
            isolation: MainActor.shared
        )
        .store(in: &entryObservationHandles)

        apply(errorDescription: entry.errorDescription)
    }

    private func apply(errorDescription: String?) {
        errorLabel.stringValue = errorDescription ?? ""
        requestLayoutInvalidation()
    }

    private func requestLayoutInvalidation() {
        needsLayout = true
        onNeedsLayout?()
    }
}

@MainActor
private final class WINetworkDetailSectionHeaderView: NSView {
    private let titleLabel = WINetworkAppKitViewFactory.makeSectionTitleLabel("")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String) {
        titleLabel.stringValue = title
    }
}

@MainActor
private func networkDetailBodyPrimaryText(entry: NetworkEntry, body: NetworkBody) -> String {
    var parts: [String] = []
    if let typeLabel = networkBodyTypeLabel(entry: entry, body: body) {
        parts.append(typeLabel)
    }
    if let size = networkBodySize(entry: entry, body: body) {
        parts.append(entry.sizeText(for: size))
    }
    if parts.isEmpty {
        return wiLocalized("network.body.unavailable", default: "Body unavailable")
    }
    return parts.joined(separator: "  ")
}

@MainActor
private func networkDetailBodySecondaryText(_ body: NetworkBody) -> String {
    switch body.fetchState {
    case .fetching:
        return wiLocalized("network.body.fetching", default: "Fetching body...")
    case .failed(let error):
        return error.localizedDescriptionText
    default:
        if body.kind == .form, body.formEntries.isEmpty == false {
            return body.formEntries.prefix(4).map {
                let value: String
                if $0.isFile, let fileName = $0.fileName, fileName.isEmpty == false {
                    value = fileName
                } else {
                    value = $0.value
                }
                return "\($0.name): \(value)"
            }.joined(separator: "\n")
        }
        return networkBodyPreviewText(body) ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#endif
