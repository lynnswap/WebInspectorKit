import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
final class WINetworkListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum CellIdentifiers {
        static let request = NSUserInterfaceItemIdentifier("WINetworkList.RequestCell")
    }

    private let inspector: WINetworkModel
    private let queryModel: WINetworkQueryModel

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyStateView = WINetworkAppKitViewFactory.makeEmptyStateView(
        title: wiLocalized("network.empty.title"),
        description: wiLocalized("network.empty.description")
    )

    private var displayedEntries: [NetworkEntry] = []
    private var isApplyingSelectionFromModel = false

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        self.queryModel = queryModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var displayedRowCountForTesting: Int {
        displayedEntries.count
    }

    var displayedRequestIDsForTesting: [Int] {
        displayedEntries.map(\.requestID)
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateView.isHidden == false
    }

    var selectedRowForTesting: Int {
        tableView.selectedRow
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureTableView()
        reloadDataFromInspector()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        _ = tableView
        return displayedEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        _ = tableColumn
        guard displayedEntries.indices.contains(row) else {
            return nil
        }

        let item = displayedEntries[row]
        let cellView: WINetworkObservingTableCellView
        if let reused = tableView.makeView(withIdentifier: CellIdentifiers.request, owner: nil) as? WINetworkObservingTableCellView {
            cellView = reused
        } else {
            cellView = makeCellView()
        }
        configureListCell(cellView, item: item)

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        guard isApplyingSelectionFromModel == false else {
            return
        }

        let selectedRow = tableView.selectedRow
        guard displayedEntries.indices.contains(selectedRow) else {
            inspector.selectEntry(nil)
            return
        }
        inspector.selectEntry(displayedEntries[selectedRow])
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

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
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 36
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WINetworkList.Column"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
    }

    private func makeCellView() -> WINetworkObservingTableCellView {
        let cellView = WINetworkObservingTableCellView()
        cellView.identifier = CellIdentifiers.request
        NSLayoutConstraint.activate([
            cellView.indicatorView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 10),
            cellView.indicatorView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            cellView.indicatorView.widthAnchor.constraint(equalToConstant: 10),
            cellView.indicatorView.heightAnchor.constraint(equalToConstant: 10),

            cellView.nameLabel.leadingAnchor.constraint(equalTo: cellView.indicatorView.trailingAnchor, constant: 10),
            cellView.nameLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),

            cellView.typeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cellView.nameLabel.trailingAnchor, constant: 12),
            cellView.typeLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -10),
            cellView.typeLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        return cellView
    }

    private func configureListCell(_ cell: WINetworkObservingTableCellView, item: NetworkEntry) {
        cell.resetObservationHandles()
        applyCellContent(cell, item: item)

        item.observe(
            \.url,
            onChange: { [weak cell, weak item] _ in
                guard let cell, let item else {
                    return
                }
                cell.nameLabel.stringValue = item.displayName
            },
            isolation: MainActor.shared
        )
        .store(in: &cell.observationHandles)

        item.observe(
            [\.fileTypeLabel, \.statusCode, \.phase],
            onChange: { [weak cell, weak item] in
                guard let cell, let item else {
                    return
                }
                cell.typeLabel.stringValue = item.fileTypeLabel
                cell.indicatorView.contentTintColor = networkStatusColor(for: item.statusSeverity)
            },
            isolation: MainActor.shared
        )
        .store(in: &cell.observationHandles)
    }

    private func applyCellContent(_ cell: WINetworkObservingTableCellView, item: NetworkEntry) {
        cell.indicatorView.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        cell.indicatorView.contentTintColor = networkStatusColor(for: item.statusSeverity)
        cell.nameLabel.stringValue = item.displayName
        cell.typeLabel.stringValue = item.fileTypeLabel
    }

    func reloadDataFromInspector(displayEntries: [NetworkEntry]? = nil) {
        _ = queryModel
        let nextDisplayedEntries = displayEntries ?? inspector.displayEntries
        let requiresFullReload = hasDifferentDisplayedEntryIdentities(comparedTo: nextDisplayedEntries)
        displayedEntries = nextDisplayedEntries
        if requiresFullReload {
            clearVisibleCellObservationHandles()
            tableView.reloadData()
        }
        syncSelectionFromModel()
        let hasEntries = displayedEntries.isEmpty == false
        scrollView.isHidden = hasEntries == false
        emptyStateView.isHidden = hasEntries
    }

    func syncSelectionFromModel() {
        isApplyingSelectionFromModel = true
        defer { isApplyingSelectionFromModel = false }

        guard let selectedEntry = inspector.selectedEntry,
              let index = displayedEntries.firstIndex(where: { $0.id == selectedEntry.id }) else {
            tableView.deselectAll(nil)
            return
        }

        if tableView.selectedRow != index {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
    }

    private func hasDifferentDisplayedEntryIdentities(comparedTo entries: [NetworkEntry]) -> Bool {
        guard displayedEntries.count == entries.count else {
            return true
        }
        return zip(displayedEntries, entries).contains { current, next in
            current !== next
        }
    }

    private func clearVisibleCellObservationHandles() {
        guard tableView.numberOfColumns > 0 else {
            return
        }
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WINetworkObservingTableCellView else {
                continue
            }
            cell.resetObservationHandles()
        }
    }
}

@MainActor
private final class WINetworkObservingTableCellView: NSTableCellView {
    let indicatorView = NSImageView()
    let nameLabel = WINetworkAppKitViewFactory.makeLabel(
        "",
        font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold),
        lineBreakMode: .byTruncatingMiddle
    )
    let typeLabel = WINetworkAppKitViewFactory.makeSecondaryLabel("")
    var observationHandles: Set<ObservationHandle> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.imageScaling = .scaleProportionallyDown

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        typeLabel.alignment = .right
        typeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        typeLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(indicatorView)
        addSubview(nameLabel)
        addSubview(typeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            observationHandles.removeAll()
        }
    }

    func resetObservationHandles() {
        observationHandles.removeAll()
    }
}
#endif
