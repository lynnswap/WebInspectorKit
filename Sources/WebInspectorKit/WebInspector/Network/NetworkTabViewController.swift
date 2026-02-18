import Foundation
import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

@MainActor
final class NetworkTabViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let inspector: WebInspector.NetworkInspector
    private let observationToken = WIObservationToken()

    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController

    init(inspector: WebInspector.NetworkInspector) {
        self.inspector = inspector
        self.listViewController = NetworkListViewController(inspector: inspector)
        self.detailViewController = NetworkDetailViewController(inspector: inspector)
        super.init(style: .doubleColumn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationToken.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        title = nil
        inspector.selectedEntryID = nil

        listViewController.onSelectEntry = { [weak self] entry in
            guard let self else { return }
            self.inspector.selectedEntryID = entry?.id
            self.detailViewController.display(entry)
            guard entry != nil else {
                if self.isCollapsed {
                    self.show(.primary)
                }
                return
            }
            if self.isCollapsed, let secondaryController = self.viewController(for: .secondary) {
                self.showDetailViewController(secondaryController, sender: self)
            }
        }

        let primary = UINavigationController(rootViewController: listViewController)
        let secondary = UINavigationController(rootViewController: detailViewController)
        setViewController(primary, for: .primary)
        setViewController(secondary, for: .secondary)

        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.selectedEntryID
            _ = self.inspector.store.entries
            self.observeSelectedEntryFields()
        }, onChange: { [weak self] in
            self?.syncDetailSelection()
        })

        syncDetailSelection()
    }

    private func syncDetailSelection() {
        let entry = inspector.store.entry(forEntryID: inspector.selectedEntryID)
        detailViewController.display(entry)
        listViewController.selectEntry(with: inspector.selectedEntryID)
        ensurePrimaryColumnIfNeeded()
    }

    private func observeSelectedEntryFields() {
        guard let selectedEntry = inspector.store.entry(forEntryID: inspector.selectedEntryID) else {
            return
        }

        _ = selectedEntry.url
        _ = selectedEntry.method
        _ = selectedEntry.statusCode
        _ = selectedEntry.statusText
        _ = selectedEntry.fileTypeLabel
        _ = selectedEntry.duration
        _ = selectedEntry.encodedBodyLength
        _ = selectedEntry.decodedBodyLength
        _ = selectedEntry.errorDescription
        _ = selectedEntry.requestHeaders
        _ = selectedEntry.responseHeaders
        _ = selectedEntry.phase
        observeBodyFields(selectedEntry.requestBody)
        observeBodyFields(selectedEntry.responseBody)
    }

    private func observeBodyFields(_ body: NetworkBody?) {
        guard let body else {
            return
        }
        _ = body.preview
        _ = body.full
        _ = body.summary
        _ = body.fetchState
        _ = body.isBase64Encoded
    }

    private func ensurePrimaryColumnIfNeeded() {
        guard isCollapsed, inspector.selectedEntryID == nil else {
            return
        }
        show(.primary)
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        if inspector.selectedEntryID == nil {
            return .primary
        }
        return proposedTopColumn
    }
}

@MainActor
private final class NetworkListViewController: UIViewController, UISearchResultsUpdating, UICollectionViewDataSource, UICollectionViewDelegate {
    private let inspector: WebInspector.NetworkInspector
    private let observationToken = WIObservationToken()
    private let listCellReuseIdentifier = "NetworkListCell"

    private var displayedEntries: [NetworkEntry] = []
    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeListLayout())
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .onDrag
        view.dataSource = self
        view.delegate = self
        view.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: listCellReuseIdentifier)
        return view
    }()
    private lazy var filterItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: makeFilterMenu()
        )
    }()
    private lazy var secondaryActionsItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: wiSecondaryActionSymbolName()),
            menu: makeSecondaryMenu()
        )
    }()
    var onSelectEntry: ((NetworkEntry?) -> Void)?

    init(inspector: WebInspector.NetworkInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationToken.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        navigationItem.title = ""

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = wiLocalized("network.search.placeholder")
        searchController.searchBar.text = inspector.searchText
        navigationItem.searchController = searchController

        navigationItem.rightBarButtonItems = [secondaryActionsItem, filterItem]

        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.displayEntries
            _ = self.inspector.effectiveResourceFilters
            _ = self.inspector.store.entries
            _ = self.inspector.searchText
        }, onChange: { [weak self] in
            self?.reloadDataFromInspector()
        })

        reloadDataFromInspector()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        let canDismiss =
            navigationController?.presentingViewController != nil ||
            splitViewController?.presentingViewController != nil ||
            tabBarController?.presentingViewController != nil
        if canDismiss {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "xmark"),
                style: .plain,
                target: self,
                action: #selector(closeInspector)
            )
        } else {
            navigationItem.leftBarButtonItem = nil
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        inspector.searchText = searchController.searchBar.text ?? ""
    }

    func selectEntry(with id: UUID?) {
        guard let id,
              let row = displayedEntries.firstIndex(where: { $0.id == id }) else {
            guard let selectedIndexPath = collectionView.indexPathsForSelectedItems?.first else {
                return
            }
            collectionView.deselectItem(at: selectedIndexPath, animated: true)
            return
        }

        let indexPath = IndexPath(item: row, section: 0)
        if collectionView.indexPathsForSelectedItems?.contains(indexPath) != true {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredVertically)
        }
    }

    @objc
    private func closeInspector() {
        if let container = splitViewController?.tabBarController, container.presentingViewController != nil {
            container.dismiss(animated: true)
            return
        }
        if let split = splitViewController, split.presentingViewController != nil {
            split.dismiss(animated: true)
            return
        }
        if let nav = navigationController, nav.presentingViewController != nil {
            nav.dismiss(animated: true)
        }
    }

    private func makeListLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.showsSeparators = true
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func reloadDataFromInspector() {
        displayedEntries = inspector.displayEntries
        collectionView.reloadData()
        selectEntry(with: inspector.selectedEntryID)
        filterItem.menu = makeFilterMenu()
        secondaryActionsItem.menu = makeSecondaryMenu()
        secondaryActionsItem.isEnabled = !inspector.store.entries.isEmpty

        let hasActiveSelectedEntry = inspector.store.entry(forEntryID: inspector.selectedEntryID) != nil
        let shouldShowEmptyState = displayedEntries.isEmpty && !hasActiveSelectedEntry
        if shouldShowEmptyState {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("network.empty.title")
            configuration.secondaryText = wiLocalized("network.empty.description")
            configuration.image = UIImage(systemName: "waveform.path.ecg.rectangle")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasEntries = !inspector.store.entries.isEmpty
        let clearAction = UIAction(
            title: wiLocalized("network.controls.clear"),
            image: UIImage(systemName: "trash"),
            attributes: hasEntries ? [.destructive] : [.destructive, .disabled]
        ) { [weak self] _ in
            self?.clearEntries()
        }
        return UIMenu(children: [clearAction])
    }

    private func makeFilterMenu() -> UIMenu {
        let allIsOn = inspector.effectiveResourceFilters.isEmpty
        let allAction = UIAction(
            title: wiLocalized("network.filter.all"),
            state: allIsOn ? .on : .off
        ) { [weak self] _ in
            self?.inspector.setResourceFilter(.all, isEnabled: true)
        }

        var resourceActions: [UIAction] = []
        for filter in NetworkResourceFilter.pickerCases {
            let isOn = inspector.activeResourceFilters.contains(filter)
            let action = UIAction(
                title: localizedTitle(for: filter),
                state: isOn ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.inspector.setResourceFilter(filter, isEnabled: !isOn)
            }
            resourceActions.append(action)
        }

        let resourceSection = UIMenu(options: [.displayInline], children: resourceActions)
        return UIMenu(children: [allAction, resourceSection])
    }

    private func clearEntries() {
        inspector.clear()
    }

    private func localizedTitle(for filter: NetworkResourceFilter) -> String {
        switch filter {
        case .all:
            return wiLocalized("network.filter.all")
        case .document:
            return wiLocalized("network.filter.document")
        case .stylesheet:
            return wiLocalized("network.filter.stylesheet")
        case .image:
            return wiLocalized("network.filter.image")
        case .font:
            return wiLocalized("network.filter.font")
        case .script:
            return wiLocalized("network.filter.script")
        case .xhrFetch:
            return wiLocalized("network.filter.xhr_fetch")
        case .other:
            return wiLocalized("network.filter.other")
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedEntries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard
            displayedEntries.indices.contains(indexPath.item),
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: listCellReuseIdentifier,
                for: indexPath
            ) as? UICollectionViewListCell
        else {
            return UICollectionViewCell()
        }

        let entry = displayedEntries[indexPath.item]
        var content = UIListContentConfiguration.cell()
        content.text = entry.displayName
        content.secondaryText = nil
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        cell.contentConfiguration = content
        cell.accessories = [
            .customView(configuration: statusIndicatorConfiguration(for: entry.statusSeverity)),
            .label(
                text: entry.fileTypeLabel,
                options: .init(
                    reservedLayoutWidth: .actual,
                    tintColor: .secondaryLabel,
                    font: .preferredFont(forTextStyle: .footnote),
                    adjustsFontForContentSizeCategory: true
                )
            ),
            .disclosureIndicator()
        ]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard displayedEntries.indices.contains(indexPath.item) else {
            onSelectEntry?(nil)
            return
        }
        onSelectEntry?(displayedEntries[indexPath.item])
    }

    private func statusIndicatorConfiguration(for severity: NetworkStatusSeverity) -> UICellAccessory.CustomViewConfiguration {
        let dotView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
        dotView.backgroundColor = networkStatusColor(for: severity)
        dotView.layer.cornerRadius = 4
        return .init(
            customView: dotView,
            placement: .leading(),
            reservedLayoutWidth: .custom(8),
            maintainsFixedSize: true
        )
    }
}

@MainActor
final class NetworkDetailViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private enum DetailRow {
        case summary(NetworkEntry)
        case header(name: String, value: String)
        case emptyHeader
        case body(entry: NetworkEntry, body: NetworkBody)
        case error(String)
    }

    private struct DetailSection {
        let title: String
        let rows: [DetailRow]
    }

    private let listCellReuseIdentifier = "NetworkDetailListCell"
    private let headerReuseIdentifier = "NetworkDetailHeaderCell"
    private let inspector: WebInspector.NetworkInspector

    private var sections: [DetailSection] = []
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: listCellReuseIdentifier)
        collectionView.register(
            UICollectionViewListCell.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: headerReuseIdentifier
        )
        return collectionView
    }()
    private var entry: NetworkEntry?

    init(inspector: WebInspector.NetworkInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        display(nil)
    }

    func display(_ entry: NetworkEntry?) {
        self.entry = entry
        guard let entry else {
            title = nil
            sections = []
            collectionView.reloadData()
            collectionView.isHidden = true
            navigationItem.rightBarButtonItem = nil
            contentUnavailableConfiguration = nil
            return
        }

        title = entry.displayName
        sections = makeSections(for: entry)
        contentUnavailableConfiguration = nil
        collectionView.isHidden = false
        collectionView.reloadData()
        navigationItem.rightBarButtonItem = makeSecondaryActionsItem(for: entry)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: listConfiguration, layoutEnvironment: environment)
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(44)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func makeSections(for entry: NetworkEntry) -> [DetailSection] {
        var sections: [DetailSection] = [
            DetailSection(
                title: wiLocalized("network.detail.section.overview", default: "Overview"),
                rows: [.summary(entry)]
            )
        ]

        let requestHeaderRows: [DetailRow]
        if entry.requestHeaders.isEmpty {
            requestHeaderRows = [.emptyHeader]
        } else {
            requestHeaderRows = entry.requestHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            title: wiLocalized("network.section.request", default: "Request"),
            rows: requestHeaderRows
        ))

        if let requestBody = entry.requestBody {
            sections.append(DetailSection(
                title: wiLocalized("network.section.body.request", default: "Request Body"),
                rows: [.body(entry: entry, body: requestBody)]
            ))
        }

        let responseHeaderRows: [DetailRow]
        if entry.responseHeaders.isEmpty {
            responseHeaderRows = [.emptyHeader]
        } else {
            responseHeaderRows = entry.responseHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            title: wiLocalized("network.section.response", default: "Response"),
            rows: responseHeaderRows
        ))

        if let responseBody = entry.responseBody {
            sections.append(DetailSection(
                title: wiLocalized("network.section.body.response", default: "Response Body"),
                rows: [.body(entry: entry, body: responseBody)]
            ))
        }

        if let errorDescription = entry.errorDescription, !errorDescription.isEmpty {
            sections.append(DetailSection(
                title: wiLocalized("network.section.error", default: "Error"),
                rows: [.error(errorDescription)]
            ))
        }

        return sections
    }

    private func makeSecondaryActionsItem(for entry: NetworkEntry) -> UIBarButtonItem? {
        guard canFetchBodies(for: entry) else {
            return nil
        }
        let fetchAction = UIAction(
            title: wiLocalized("network.body.fetch", default: "Fetch Body"),
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in
            self?.fetchBodies(force: true)
        }
        let menu = UIMenu(children: [fetchAction])
        return UIBarButtonItem(image: UIImage(systemName: wiSecondaryActionSymbolName()), menu: menu)
    }

    private func canFetchBodies(for entry: NetworkEntry) -> Bool {
        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
    }

    private func fetchBodies(force: Bool) {
        guard let entry else {
            return
        }
        let entryID = entry.id

        Task {
            if let requestBody = entry.requestBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: requestBody, force: force)
            }
            if let responseBody = entry.responseBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: responseBody, force: force)
            }
            guard self.inspector.selectedEntryID == entryID else {
                return
            }
            self.display(entry)
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else {
            return 0
        }
        return sections[section].rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard
            sections.indices.contains(indexPath.section),
            sections[indexPath.section].rows.indices.contains(indexPath.item),
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: listCellReuseIdentifier,
                for: indexPath
            ) as? UICollectionViewListCell
        else {
            return UICollectionViewCell()
        }

        cell.accessories = []
        var content = UIListContentConfiguration.cell()

        let row = sections[indexPath.section].rows[indexPath.item]
        switch row {
        case .summary(let entry):
            var summaryParts: [String] = ["\(entry.statusLabel)"]
            if let duration = entry.duration {
                summaryParts.append("◷ \(entry.durationText(for: duration))")
            }
            if let encodedBodyLength = entry.encodedBodyLength {
                summaryParts.append("↓ \(entry.sizeText(for: encodedBodyLength))")
            }
            content = makeElementLikeSubtitleConfiguration(
                title: summaryParts.joined(separator: "  "),
                detail: entry.url,
                titleColor: networkStatusColor(for: entry.statusSeverity),
                detailColor: .label,
                titleNumberOfLines: 1,
                detailNumberOfLines: 4
            )
        case .header(let name, let value):
            content = makeElementLikeSubtitleConfiguration(
                title: name,
                detail: value,
                titleColor: .secondaryLabel,
                detailColor: .label
            )
        case .emptyHeader:
            content = UIListContentConfiguration.cell()
            content.text = wiLocalized("network.headers.empty", default: "No headers")
            content.textProperties.color = .secondaryLabel
        case .body(let entry, let body):
            content = makeElementLikeSubtitleConfiguration(
                title: makeBodyPrimaryText(entry: entry, body: body),
                detail: makeBodySecondaryText(body),
                titleColor: .secondaryLabel,
                detailColor: .label,
                titleNumberOfLines: 1,
                detailNumberOfLines: 6
            )
            cell.accessories = [.disclosureIndicator()]
        case .error(let error):
            content = UIListContentConfiguration.cell()
            content.text = error
            content.textProperties.color = .systemOrange
            content.textProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
        return cell
    }

    private func makeElementLikeSubtitleConfiguration(
        title: String,
        detail: String,
        titleColor: UIColor,
        detailColor: UIColor,
        titleNumberOfLines: Int = 1,
        detailNumberOfLines: Int = 0
    ) -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = title
        configuration.secondaryText = detail
        configuration.textProperties.numberOfLines = titleNumberOfLines
        configuration.secondaryTextProperties.numberOfLines = detailNumberOfLines
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        configuration.textProperties.color = titleColor
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
        configuration.secondaryTextProperties.color = detailColor
        return configuration
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard
            kind == UICollectionView.elementKindSectionHeader,
            sections.indices.contains(indexPath.section),
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: headerReuseIdentifier,
                for: indexPath
            ) as? UICollectionViewListCell
        else {
            return UICollectionReusableView()
        }
        var configuration = UIListContentConfiguration.header()
        configuration.text = sections[indexPath.section].title
        header.contentConfiguration = configuration
        return header
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard
            sections.indices.contains(indexPath.section),
            sections[indexPath.section].rows.indices.contains(indexPath.item)
        else {
            return false
        }
        if case .body = sections[indexPath.section].rows[indexPath.item] {
            return true
        }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard
            sections.indices.contains(indexPath.section),
            sections[indexPath.section].rows.indices.contains(indexPath.item)
        else {
            return
        }

        let row = sections[indexPath.section].rows[indexPath.item]
        if case let .body(entry, body) = row {
            let preview = NetworkBodyPreviewViewController(entry: entry, inspector: inspector, bodyState: body)
            navigationController?.pushViewController(preview, animated: true)
        }
    }

    private func makeBodyPrimaryText(entry: NetworkEntry, body: NetworkBody) -> String {
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

    private func makeBodySecondaryText(_ body: NetworkBody) -> String {
        switch body.fetchState {
        case .fetching:
            return wiLocalized("network.body.fetching", default: "Fetching body...")
        case .failed(let error):
            return error.localizedDescriptionText
        default:
            if body.kind == .form, !body.formEntries.isEmpty {
                return body.formEntries.prefix(4).map {
                    let value: String
                    if $0.isFile, let fileName = $0.fileName, !fileName.isEmpty {
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
}

@MainActor
private final class NetworkBodyPreviewViewController: UIViewController {
    private enum PreviewMode {
        case text
        case json
    }

    private let entry: NetworkEntry
    private let inspector: WebInspector.NetworkInspector
    private let bodyState: NetworkBody

    private var mode: PreviewMode = .text
    private lazy var modeControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            wiLocalized("network.body.preview.mode.text", default: "Text"),
            wiLocalized("network.body.preview.mode.json", default: "JSON")
        ])
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        return control
    }()
    private let textView = UITextView()

    init(entry: NetworkEntry, inspector: WebInspector.NetworkInspector, bodyState: NetworkBody) {
        self.entry = entry
        self.inspector = inspector
        self.bodyState = bodyState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        modeControl.isHidden = true
        navigationItem.titleView = modeControl
        refreshContent()

        Task {
            await inspector.fetchBodyIfNeeded(for: entry, body: bodyState)
            self.refreshContent()
        }
    }

    @objc
    private func modeChanged() {
        mode = modeControl.selectedSegmentIndex == 1 ? .json : .text
        refreshContent()
    }

    private func refreshContent() {
        title = bodyState.role == .request
            ? wiLocalized("network.section.body.request", default: "Request Body")
            : wiLocalized("network.section.body.response", default: "Response Body")

        let previewData = bodyState.previewData
        let hasJSON = previewData.jsonNodes != nil
        modeControl.isHidden = !hasJSON
        if !hasJSON {
            mode = .text
        }

        let fetchAction = UIAction(
            title: wiLocalized("network.body.fetch", default: "Fetch Body"),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: bodyState.canFetchBody ? [] : [.disabled]
        ) { [weak self] _ in
            self?.fetch(force: true)
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: wiSecondaryActionSymbolName()),
            menu: UIMenu(children: [fetchAction])
        )

        let text: String
        switch mode {
        case .text:
            text = previewData.text ?? bodyState.summary ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
        case .json:
            text = prettyJSONString(from: previewData.text) ?? previewData.text ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
        }

        switch bodyState.fetchState {
        case .fetching:
            textView.text = wiLocalized("network.body.fetching", default: "Fetching body...")
        case .failed(let error):
            textView.text = text + "\n\n\(error.localizedDescriptionText)"
        default:
            textView.text = text
        }
    }

    private func fetch(force: Bool) {
        Task {
            await inspector.fetchBodyIfNeeded(for: entry, body: bodyState, force: force)
            self.refreshContent()
        }
    }

    private func prettyJSONString(from text: String?) -> String? {
        guard let text, let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        guard
            let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return pretty
    }
}

private func networkStatusColor(for severity: NetworkStatusSeverity) -> UIColor {
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

private func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
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

private func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
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

private func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

private func decodedBodyText(from body: NetworkBody) -> String? {
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

#elseif canImport(AppKit)
import AppKit

@MainActor
final class NetworkTabViewController: NSSplitViewController {
    private let inspector: WebInspector.NetworkInspector
    private let observationToken = WIObservationToken()

    private let listViewController: NetworkMacListViewController
    private let detailViewController: NetworkMacDetailViewController

    init(inspector: WebInspector.NetworkInspector) {
        self.inspector = inspector
        self.listViewController = NetworkMacListViewController(inspector: inspector)
        self.detailViewController = NetworkMacDetailViewController(inspector: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationToken.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inspector.selectedEntryID = nil

        let listItem = NSSplitViewItem(viewController: listViewController)
        let detailItem = NSSplitViewItem(viewController: detailViewController)
        splitViewItems = [listItem, detailItem]

        listViewController.onSelectEntry = { [weak self] entry in
            guard let self else { return }
            self.inspector.selectedEntryID = entry?.id
            self.detailViewController.display(entry)
        }

        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.selectedEntryID
            _ = self.inspector.store.entries
            self.observeSelectedEntryFields()
        }, onChange: { [weak self] in
            self?.syncDetailSelection()
        })

        syncDetailSelection()
    }

    private func syncDetailSelection() {
        let entry = inspector.store.entry(forEntryID: inspector.selectedEntryID)
        detailViewController.display(entry)
        listViewController.selectEntry(with: inspector.selectedEntryID)
    }

    private func observeSelectedEntryFields() {
        guard let selectedEntry = inspector.store.entry(forEntryID: inspector.selectedEntryID) else {
            return
        }

        _ = selectedEntry.url
        _ = selectedEntry.method
        _ = selectedEntry.statusCode
        _ = selectedEntry.statusText
        _ = selectedEntry.fileTypeLabel
        _ = selectedEntry.duration
        _ = selectedEntry.encodedBodyLength
        _ = selectedEntry.decodedBodyLength
        _ = selectedEntry.errorDescription
        _ = selectedEntry.requestHeaders
        _ = selectedEntry.responseHeaders
        _ = selectedEntry.phase
        observeBodyFields(selectedEntry.requestBody)
        observeBodyFields(selectedEntry.responseBody)
    }

    private func observeBodyFields(_ body: NetworkBody?) {
        guard let body else {
            return
        }
        _ = body.preview
        _ = body.full
        _ = body.summary
        _ = body.fetchState
        _ = body.isBase64Encoded
    }
}

@MainActor
private final class NetworkMacListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let inspector: WebInspector.NetworkInspector
    private let observationToken = WIObservationToken()

    private let searchField = NSSearchField()
    private let filterButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let tableView = NSTableView()

    private var displayedEntries: [NetworkEntry] = []
    var onSelectEntry: ((NetworkEntry?) -> Void)?

    init(inspector: WebInspector.NetworkInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationToken.invalidate()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        searchField.placeholderString = wiLocalized("network.search.placeholder")
        searchField.delegate = self

        filterButton.title = wiLocalized("network.controls.filter")
        filterButton.bezelStyle = .rounded
        filterButton.target = self
        filterButton.action = #selector(showFilterMenu(_:))
        rebuildFilterMenu()

        clearButton.title = wiLocalized("network.controls.clear")
        clearButton.target = self
        clearButton.action = #selector(clearEntries)
        clearButton.bezelStyle = .rounded

        let toolbar = NSStackView(views: [searchField, filterButton, clearButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameColumn.title = wiLocalized("network.table.column.request")
        nameColumn.width = 240
        tableView.addTableColumn(nameColumn)

        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Status"))
        statusColumn.title = wiLocalized("network.table.column.status")
        statusColumn.width = 90
        tableView.addTableColumn(statusColumn)

        let methodColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Method"))
        methodColumn.title = wiLocalized("network.table.column.method")
        methodColumn.width = 72
        tableView.addTableColumn(methodColumn)

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Type"))
        typeColumn.title = wiLocalized("network.table.column.type")
        typeColumn.width = 88
        tableView.addTableColumn(typeColumn)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .inset
        tableView.rowHeight = 34
        tableView.usesAlternatingRowBackgroundColors = false

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(toolbar)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.displayEntries
            _ = self.inspector.effectiveResourceFilters
            _ = self.inspector.store.entries
            _ = self.inspector.searchText
        }, onChange: { [weak self] in
            self?.reloadDataFromInspector()
        })

        reloadDataFromInspector()
    }

    func controlTextDidChange(_ obj: Notification) {
        inspector.searchText = searchField.stringValue
    }

    func selectEntry(with id: UUID?) {
        guard let id,
              let row = displayedEntries.firstIndex(where: { $0.id == id })
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func reloadDataFromInspector() {
        displayedEntries = inspector.displayEntries
        tableView.reloadData()
        clearButton.isEnabled = !inspector.store.entries.isEmpty
        rebuildFilterMenu()
    }

    private func rebuildFilterMenu() {
        let menu = NSMenu()
        let allItem = NSMenuItem(
            title: wiLocalized("network.filter.all"),
            action: #selector(selectAllFilters(_:)),
            keyEquivalent: ""
        )
        allItem.target = self
        allItem.state = inspector.effectiveResourceFilters.isEmpty ? .on : .off
        menu.addItem(allItem)
        menu.addItem(.separator())

        for filter in NetworkResourceFilter.pickerCases {
            let item = NSMenuItem(
                title: localizedTitle(for: filter),
                action: #selector(toggleFilter(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = filter.rawValue
            item.state = inspector.activeResourceFilters.contains(filter) ? .on : .off
            menu.addItem(item)
        }

        filterButton.menu = menu
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedEntries.indices.contains(row) else {
            return nil
        }

        let entry = displayedEntries[row]
        let identifier = NSUserInterfaceItemIdentifier("Cell-\(tableColumn?.identifier.rawValue ?? "")")
        let textField: NSTextField

        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.lineBreakMode = .byTruncatingMiddle
        }

        switch tableColumn?.identifier.rawValue {
        case "Status":
            textField.stringValue = entry.statusLabel
            textField.textColor = networkStatusColor(for: entry.statusSeverity)
            textField.font = WIUIStyle.macOS.bodyFont
        case "Method":
            textField.stringValue = entry.method
            textField.font = WIUIStyle.macOS.detailFont
            textField.textColor = .secondaryLabelColor
        case "Type":
            textField.stringValue = entry.fileTypeLabel
            textField.font = WIUIStyle.macOS.detailFont
            textField.textColor = .secondaryLabelColor
        default:
            textField.stringValue = entry.displayName
            textField.font = WIUIStyle.macOS.bodyFont
            textField.textColor = .labelColor
        }
        return textField
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, displayedEntries.indices.contains(row) else {
            onSelectEntry?(nil)
            return
        }
        onSelectEntry?(displayedEntries[row])
    }

    @objc
    private func selectAllFilters(_ sender: NSMenuItem) {
        inspector.setResourceFilter(.all, isEnabled: true)
        rebuildFilterMenu()
    }

    @objc
    private func showFilterMenu(_ sender: NSButton) {
        guard let menu = sender.menu else {
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc
    private func toggleFilter(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let filter = NetworkResourceFilter(rawValue: rawValue)
        else {
            return
        }

        let currentlyEnabled = inspector.activeResourceFilters.contains(filter)
        inspector.setResourceFilter(filter, isEnabled: !currentlyEnabled)
        rebuildFilterMenu()
    }

    @objc
    private func clearEntries() {
        inspector.clear()
    }

    private func localizedTitle(for filter: NetworkResourceFilter) -> String {
        switch filter {
        case .all:
            return wiLocalized("network.filter.all")
        case .document:
            return wiLocalized("network.filter.document")
        case .stylesheet:
            return wiLocalized("network.filter.stylesheet")
        case .image:
            return wiLocalized("network.filter.image")
        case .font:
            return wiLocalized("network.filter.font")
        case .script:
            return wiLocalized("network.filter.script")
        case .xhrFetch:
            return wiLocalized("network.filter.xhr_fetch")
        case .other:
            return wiLocalized("network.filter.other")
        }
    }
}

@MainActor
private final class NetworkMacDetailViewController: NSViewController {
    private enum DetailRow {
        case summary(NetworkEntry)
        case header(name: String, value: String)
        case emptyHeader
        case body(entry: NetworkEntry, body: NetworkBody)
        case error(String)
    }

    private struct DetailSection {
        let title: String
        let rows: [DetailRow]
    }

    private let inspector: WebInspector.NetworkInspector

    private let fetchButton = NSButton(title: "", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")
    private let contentStackView = NSStackView()
    private var entry: NetworkEntry?

    init(inspector: WebInspector.NetworkInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        fetchButton.title = wiLocalized("network.body.fetch", default: "Fetch Body")
        fetchButton.bezelStyle = .rounded
        fetchButton.target = self
        fetchButton.action = #selector(fetchBodies)
        fetchButton.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        contentStackView.orientation = .vertical
        contentStackView.spacing = WIUIStyle.macOS.sectionSpacing
        contentStackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(contentStackView)
        NSLayoutConstraint.activate([
            contentStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: WIUIStyle.macOS.verticalPadding),
            contentStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: WIUIStyle.macOS.horizontalPadding),
            contentStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -WIUIStyle.macOS.horizontalPadding),
            contentStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -WIUIStyle.macOS.verticalPadding),
            contentStackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -(WIUIStyle.macOS.horizontalPadding * 2))
        ])

        emptyLabel.font = WIUIStyle.macOS.bodyFont
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(fetchButton)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            fetchButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            fetchButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: fetchButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])

        display(nil)
    }

    func display(_ entry: NetworkEntry?) {
        self.entry = entry

        guard let entry else {
            emptyLabel.stringValue = "\(wiLocalized("network.empty.title"))\n\n\(wiLocalized("network.empty.description"))"
            emptyLabel.isHidden = false
            contentStackView.isHidden = true
            fetchButton.isEnabled = false
            return
        }

        emptyLabel.isHidden = true
        contentStackView.isHidden = false
        rebuildContent(for: entry)
        fetchButton.isEnabled = canFetchBodies(for: entry)
    }

    @objc
    private func fetchBodies() {
        guard let entry else {
            return
        }

        let entryID = entry.id
        Task {
            if let requestBody = entry.requestBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: requestBody, force: true)
            }
            if let responseBody = entry.responseBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: responseBody, force: true)
            }
            guard self.inspector.selectedEntryID == entryID else {
                return
            }
            self.rebuildContent(for: entry)
            self.fetchButton.isEnabled = self.canFetchBodies(for: entry)
        }
    }

    private func rebuildContent(for entry: NetworkEntry) {
        contentStackView.arrangedSubviews.forEach { arrangedSubview in
            contentStackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        for section in makeSections(for: entry) {
            contentStackView.addArrangedSubview(makeSectionHeader(section.title))
            section.rows.forEach { row in
                contentStackView.addArrangedSubview(makeRowView(row))
            }
        }
    }

    private func makeSections(for entry: NetworkEntry) -> [DetailSection] {
        var sections: [DetailSection] = [
            DetailSection(
                title: wiLocalized("network.detail.section.overview", default: "Overview"),
                rows: [.summary(entry)]
            )
        ]

        let requestRows: [DetailRow]
        if entry.requestHeaders.isEmpty {
            requestRows = [.emptyHeader]
        } else {
            requestRows = entry.requestHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            title: wiLocalized("network.section.request", default: "Request"),
            rows: requestRows
        ))

        if let requestBody = entry.requestBody {
            sections.append(DetailSection(
                title: wiLocalized("network.section.body.request", default: "Request Body"),
                rows: [.body(entry: entry, body: requestBody)]
            ))
        }

        let responseRows: [DetailRow]
        if entry.responseHeaders.isEmpty {
            responseRows = [.emptyHeader]
        } else {
            responseRows = entry.responseHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            title: wiLocalized("network.section.response", default: "Response"),
            rows: responseRows
        ))

        if let responseBody = entry.responseBody {
            sections.append(DetailSection(
                title: wiLocalized("network.section.body.response", default: "Response Body"),
                rows: [.body(entry: entry, body: responseBody)]
            ))
        }

        if let errorDescription = entry.errorDescription, !errorDescription.isEmpty {
            sections.append(DetailSection(
                title: wiLocalized("network.section.error", default: "Error"),
                rows: [.error(errorDescription)]
            ))
        }

        return sections
    }

    private func makeSectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = WIUIStyle.macOS.headerFont
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeRowView(_ row: DetailRow) -> NSView {
        switch row {
        case .summary(let entry):
            return makeCardView {
                let metrics = NSTextField(labelWithString: makeSummaryText(for: entry))
                metrics.font = WIUIStyle.macOS.bodyFont
                metrics.textColor = networkStatusColor(for: entry.statusSeverity)

                let url = NSTextField(wrappingLabelWithString: entry.url)
                url.font = WIUIStyle.macOS.bodyFont
                url.textColor = .labelColor
                url.lineBreakMode = .byCharWrapping

                return [metrics, url]
            }
        case .header(let name, let value):
            return makeCardView {
                let key = NSTextField(labelWithString: name)
                key.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                key.textColor = .secondaryLabelColor

                let detail = NSTextField(wrappingLabelWithString: value)
                detail.font = WIUIStyle.macOS.detailFont
                detail.textColor = .labelColor

                return [key, detail]
            }
        case .emptyHeader:
            return makeCardView {
                let label = NSTextField(labelWithString: wiLocalized("network.headers.empty", default: "No headers"))
                label.font = WIUIStyle.macOS.bodyFont
                label.textColor = .secondaryLabelColor
                return [label]
            }
        case .body(let entry, let body):
            return makeCardView {
                let title = NSTextField(labelWithString: makeBodyPrimaryText(entry: entry, body: body))
                title.font = WIUIStyle.macOS.bodyFont
                title.textColor = .secondaryLabelColor

                let preview = NSTextField(wrappingLabelWithString: makeBodySecondaryText(body))
                preview.font = WIUIStyle.macOS.detailFont
                preview.textColor = .labelColor
                preview.maximumNumberOfLines = 0

                return [title, preview]
            }
        case .error(let message):
            return makeCardView {
                let label = NSTextField(wrappingLabelWithString: message)
                label.font = WIUIStyle.macOS.bodyFont
                label.textColor = .systemOrange
                return [label]
            }
        }
    }

    private func makeCardView(content: () -> [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = WIUIStyle.macOS.cardCornerRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = WIUIStyle.macOS.cardBorderColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: content())
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = WIUIStyle.macOS.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: WIUIStyle.macOS.verticalPadding),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: WIUIStyle.macOS.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -WIUIStyle.macOS.horizontalPadding),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -WIUIStyle.macOS.verticalPadding)
        ])
        return card
    }

    private func makeSummaryText(for entry: NetworkEntry) -> String {
        var parts: [String] = [entry.statusLabel]
        if let duration = entry.duration {
            parts.append("◷ \(entry.durationText(for: duration))")
        }
        if let size = entry.encodedBodyLength {
            parts.append("↓ \(entry.sizeText(for: size))")
        }
        return parts.joined(separator: "  ")
    }

    private func makeBodyPrimaryText(entry: NetworkEntry, body: NetworkBody) -> String {
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

    private func makeBodySecondaryText(_ body: NetworkBody) -> String {
        switch body.fetchState {
        case .fetching:
            return wiLocalized("network.body.fetching", default: "Fetching body...")
        case .failed(let error):
            return error.localizedDescriptionText
        default:
            if body.kind == .form, !body.formEntries.isEmpty {
                return body.formEntries.prefix(4).map {
                    let value: String
                    if $0.isFile, let fileName = $0.fileName, !fileName.isEmpty {
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

    private func canFetchBodies(for entry: NetworkEntry) -> Bool {
        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
    }
}

private func networkStatusColor(for severity: NetworkStatusSeverity) -> NSColor {
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
        return .secondaryLabelColor
    }
}

private func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
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

private func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
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

private func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

private func decodedBodyText(from body: NetworkBody) -> String? {
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
