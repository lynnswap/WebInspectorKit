#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class NetworkDetailViewController: UIViewController, UICollectionViewDelegate {
    private struct HeaderField: Hashable {
        var name: String
        var value: String
    }

    private struct BodyMetadataField: Hashable {
        var name: String
        var value: String
    }

    private enum SectionIdentifier: Int, CaseIterable, Hashable {
        case body
        case headers
    }

    private enum ItemIdentifier: Hashable {
        case bodyMetadata(BodyMetadataField)
        case bodyLink(NetworkBodyRole)
        case header(HeaderField)
    }

    private let model: NetworkPanelModel
    private let observationScope = ObservationScope()
    private var modePalette: UIView?
    private lazy var modeSegmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: NetworkDetailMode.allCases.map(\.title))
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = modeIndex(for: mode)
        control.accessibilityIdentifier = "WebInspector.Network.DetailModeSegmentedControl"
        control.addTarget(self, action: #selector(modeSegmentedControlValueChanged(_:)), for: .valueChanged)
        return control
    }()
    private lazy var modePaletteContentView = NetworkDetailModePaletteContentView(
        segmentedControl: modeSegmentedControl
    )
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeListLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "WebInspector.Network.Detail"
        collectionView.delegate = self
        collectionView.isHidden = true
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()
    fileprivate var mode: NetworkDetailMode = .request {
        didSet {
            guard mode != oldValue else {
                return
            }
            startObservingModel()
            renderModeControl()
        }
    }

    private var selectedRequest: NetworkRequest? {
        model.selectedRequest
    }

    package init(model: NetworkPanelModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        installCollectionView()
        installModePalette()
        startObservingModel()
    }

    package func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else {
            return false
        }
        if case .bodyLink(let role) = item, let selectedRequest {
            return body(in: selectedRequest, for: role) != nil
        }
        return false
    }

    package func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .bodyLink(let role) = item,
              let selectedRequest else {
            return
        }
        pushBody(for: role, in: selectedRequest)
    }

    private func startObservingModel() {
        observationScope.observe(model) { [weak self] event, model in
            self?.render(selectedRequest: model.selectedRequest, reloadData: event.kind == .initial)
        }
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
    }

    private func installCollectionView() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func installModePalette() {
        let palette = unsafe Self.makeNavigationBarPalette(contentView: modePaletteContentView)
        _ = unsafe navigationItem.perform(NetworkDetailModePaletteRuntime.attachSelector, with: palette)
        modePalette = palette
        renderModeControl()
    }

    @unsafe private static func makeNavigationBarPalette(contentView: UIView) -> UIView {
        let paletteClass = NSClassFromString(NetworkDetailModePaletteRuntime.className) as! NSObject.Type
        let allocated = unsafe paletteClass.perform(NetworkDetailModePaletteRuntime.allocateSelector)!.takeUnretainedValue()
        let palette = unsafe (allocated as AnyObject)
            .perform(NetworkDetailModePaletteRuntime.contentInitializerSelector, with: contentView)!
            .takeUnretainedValue() as! UIView
        palette.setValue(1, forKey: NetworkDetailModePaletteRuntime.marginPolicyKey)
        return palette
    }

    private static func makeListLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary

        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(
                using: listConfiguration,
                layoutEnvironment: environment
            )
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        let fieldCellRegistration = UICollectionView.CellRegistration<NetworkFieldCell, ItemIdentifier> {
            [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard
                let self,
                let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else {
                return
            }
            var configuration = UIListContentConfiguration.header()
            configuration.text = self.title(for: section)
            header.contentConfiguration = configuration
        }

        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            return collectionView.dequeueConfiguredReusableCell(
                using: fieldCellRegistration,
                for: indexPath,
                item: item
            )
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func render(selectedRequest request: NetworkRequest?, reloadData: Bool) {
        title = request?.displayName

        guard isViewLoaded else {
            return
        }
        guard let request else {
            showEmptySelection()
            renderModeControl(selectedRequest: nil)
            return
        }

        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        renderCurrentMode(selectedRequest: request, reloadData: reloadData)
        renderModeControl(selectedRequest: request)
    }

    @objc private func modeSegmentedControlValueChanged(_ sender: UISegmentedControl) {
        guard NetworkDetailMode.allCases.indices.contains(sender.selectedSegmentIndex) else {
            renderModeControl()
            return
        }

        let selectedMode = NetworkDetailMode.allCases[sender.selectedSegmentIndex]
        guard isModeEnabled(selectedMode, selectedRequest: selectedRequest) else {
            renderModeControl()
            return
        }
        mode = selectedMode
    }

    private func renderModeControl(selectedRequest request: NetworkRequest? = nil) {
        let request = request ?? selectedRequest
        modeSegmentedControl.isEnabled = request != nil
        modeSegmentedControl.selectedSegmentIndex = modeIndex(for: mode)
        modeSegmentedControl.accessibilityLabel = mode.title
        for (index, mode) in NetworkDetailMode.allCases.enumerated() {
            modeSegmentedControl.setEnabled(
                isModeEnabled(mode, selectedRequest: request),
                forSegmentAt: index
            )
        }
    }

    private func isModeEnabled(
        _ mode: NetworkDetailMode,
        selectedRequest request: NetworkRequest?
    ) -> Bool {
        guard let request else {
            return false
        }
        switch mode {
        case .request:
            return true
        case .response:
            return request.response != nil
        }
    }

    private func modeIndex(for mode: NetworkDetailMode) -> Int {
        NetworkDetailMode.allCases.firstIndex(of: mode) ?? UISegmentedControl.noSegment
    }

    private func renderCurrentMode(selectedRequest: NetworkRequest? = nil, reloadData: Bool) {
        guard isViewLoaded else {
            return
        }
        guard let selectedRequest = selectedRequest ?? self.selectedRequest else {
            return
        }
        guard resetUnavailableModeIfNeeded(for: selectedRequest) == false else {
            return
        }

        showDetailList()
        if reloadData {
            applySnapshotUsingReloadData(for: selectedRequest)
        } else {
            applySnapshot(for: selectedRequest)
        }
        if mode == .response {
            model.fetchResponseBodyIfNeeded(for: selectedRequest)
        }
    }

    private func showEmptySelection() {
        if collectionView.isHidden == false {
            collectionView.isHidden = true
        }
        if let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
           configuration.text == String(localized: "network.empty.selection.title", bundle: .module) {
            applyEmptySnapshotUsingReloadData()
            return
        }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = String(localized: "network.empty.selection.title", bundle: .module)
        configuration.textProperties.color = .secondaryLabel
        contentUnavailableConfiguration = configuration
        applyEmptySnapshotUsingReloadData()
    }

    private func showDetailList() {
        if collectionView.isHidden {
            collectionView.isHidden = false
        }
    }

    private func resetUnavailableModeIfNeeded(for request: NetworkRequest) -> Bool {
        guard mode == .response, request.response == nil else {
            return false
        }
        mode = .request
        return true
    }

    private func body(in request: NetworkRequest, for role: NetworkBodyRole) -> NetworkBody? {
        switch role {
        case .request:
            request.requestBody
        case .response:
            request.responseBody
        }
    }

    private func pushBody(for role: NetworkBodyRole, in request: NetworkRequest) {
        let bodyViewController = NetworkBodyViewController()
        bodyViewController.title = title(for: role)
        bodyViewController.display(body: body(in: request, for: role))
        navigationController?.pushViewController(bodyViewController, animated: true)
        if role == .response {
            model.fetchResponseBodyIfNeeded(for: request)
        }
    }

    private func makeSnapshot(
        for selectedRequest: NetworkRequest
    ) -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        snapshot.appendSections([.body])
        snapshot.appendItems(bodyItems(in: selectedRequest, for: mode.bodyRole), toSection: .body)

        let headers = headerFields(from: headers(in: selectedRequest, for: mode))
        if headers.isEmpty == false {
            snapshot.appendSections([.headers])
            snapshot.appendItems(headers.map { .header($0) }, toSection: .headers)
        }
        return snapshot
    }

    private func bodyItems(
        in request: NetworkRequest,
        for role: NetworkBodyRole
    ) -> [ItemIdentifier] {
        var items: [ItemIdentifier] = []
        if let mimeType = mimeType(in: request, for: role) {
            items.append(
                .bodyMetadata(
                    BodyMetadataField(
                        name: String(localized: "network.body.metadata.mime_type", defaultValue: "MIME Type", bundle: .module),
                        value: mimeType
                    )
                )
            )
        }
        items.append(.bodyLink(role))
        return items
    }

    private func mimeType(
        in request: NetworkRequest,
        for role: NetworkBodyRole
    ) -> String? {
        switch role {
        case .request:
            return mimeType(from: nil, headers: request.request.headers)
        case .response:
            return mimeType(from: request.response?.mimeType, headers: request.response?.headers ?? [:])
        }
    }

    private func mimeType(
        from explicitMimeType: String?,
        headers: [String: String]
    ) -> String? {
        let rawMimeType = explicitMimeType ?? headerValue(named: "content-type", in: headers)
        let mimeType = rawMimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mimeType, mimeType.isEmpty == false else {
            return nil
        }
        return mimeType
    }

    private func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func headers(
        in request: NetworkRequest,
        for mode: NetworkDetailMode
    ) -> [String: String] {
        switch mode {
        case .request:
            request.request.headers
        case .response:
            request.response?.headers ?? [:]
        }
    }

    private func headerFields(from headers: [String: String]) -> [HeaderField] {
        headers
            .map { HeaderField(name: $0.key, value: $0.value) }
            .sorted {
                let nameComparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameComparison == .orderedSame {
                    return $0.value < $1.value
                }
                return nameComparison == .orderedAscending
            }
    }

    private func applySnapshot(for selectedRequest: NetworkRequest) {
        guard isViewLoaded else {
            return
        }
        let snapshot = makeSnapshot(for: selectedRequest)
        let currentSnapshot = dataSource.snapshot()
        guard currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers else {
            return
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applySnapshotUsingReloadData(for selectedRequest: NetworkRequest) {
        guard isViewLoaded else {
            return
        }
        let snapshot = makeSnapshot(for: selectedRequest)
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    private func applyEmptySnapshotUsingReloadData() {
        guard isViewLoaded else {
            return
        }
        let snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        let currentSnapshot = dataSource.snapshot()
        guard currentSnapshot.numberOfItems != 0 || currentSnapshot.numberOfSections != 0 else {
            return
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    private func configure(_ cell: NetworkFieldCell, item: ItemIdentifier) {
        switch item {
        case .bodyMetadata(let field):
            cell.bindBodyMetadata(name: field.name, value: field.value)
        case .bodyLink(let role):
            let body = selectedRequest.flatMap { request in
                self.body(in: request, for: role)
            }
            cell.bindBodyLink(
                title: String(localized: "network.section.body", defaultValue: "Body", bundle: .module),
                isEnabled: body != nil
            )
        case .header(let field):
            cell.bindHeader(name: field.name, value: field.value)
        }
    }

    private func title(for role: NetworkBodyRole) -> String {
        switch role {
        case .request:
            String(localized: "network.section.body.request", bundle: .module)
        case .response:
            String(localized: "network.section.body.response", bundle: .module)
        }
    }

    private func title(for section: SectionIdentifier) -> String {
        switch section {
        case .body:
            switch mode {
            case .request:
                String(localized: "network.section.body.request_data", defaultValue: "Request Data", bundle: .module)
            case .response:
                String(localized: "network.section.body.response_data", defaultValue: "Response Data", bundle: .module)
            }
        case .headers:
            String(localized: "network.section.headers", defaultValue: "Headers", bundle: .module)
        }
    }
}

private enum NetworkDetailModePaletteRuntime {
    // Original: _UINavigationBarPalette
    static let className = decoded([
        0x02, 0x08, 0x14, 0x13, 0x3c, 0x2b, 0x34, 0x3a,
        0x3c, 0x29, 0x34, 0x32, 0x33, 0x1f, 0x3c, 0x2f,
        0x0d, 0x3c, 0x31, 0x38, 0x29, 0x29, 0x38,
    ])
    // Original: _setBottomPalette:
    static let attachSelector = NSSelectorFromString(decoded([
        0x02, 0x2e, 0x38, 0x29, 0x1f, 0x32, 0x29, 0x29,
        0x32, 0x30, 0x0d, 0x3c, 0x31, 0x38, 0x29, 0x29,
        0x38, 0x67,
    ]))
    // Original: alloc
    static let allocateSelector = NSSelectorFromString(decoded([
        0x3c, 0x31, 0x31, 0x32, 0x3e,
    ]))
    // Original: initWithContentView:
    static let contentInitializerSelector = NSSelectorFromString(decoded([
        0x34, 0x33, 0x34, 0x29, 0x0a, 0x34, 0x29, 0x35,
        0x1e, 0x32, 0x33, 0x29, 0x38, 0x33, 0x29, 0x0b,
        0x34, 0x38, 0x2a, 0x67,
    ]))
    // Original: _contentViewMarginType
    static let marginPolicyKey = decoded([
        0x02, 0x3e, 0x32, 0x33, 0x29, 0x38, 0x33, 0x29,
        0x0b, 0x34, 0x38, 0x2a, 0x10, 0x3c, 0x2f, 0x3a,
        0x34, 0x33, 0x09, 0x24, 0x2d, 0x38,
    ])

    private static func decoded(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0x5d }, as: UTF8.self)
    }
}

@MainActor
private final class NetworkDetailModePaletteContentView: UIView {
    private let segmentedControl: UISegmentedControl

    init(segmentedControl: UISegmentedControl) {
        self.segmentedControl = segmentedControl
        let height = Self.preferredHeight(for: segmentedControl)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height))
        preservesSuperviewLayoutMargins = true
        addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            segmentedControl.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            segmentedControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight(for: segmentedControl))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: Self.preferredHeight(for: segmentedControl))
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        fittingSize(for: targetSize)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        fittingSize(for: targetSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func fittingSize(for targetSize: CGSize) -> CGSize {
        let width = targetSize.width == 0 ? UIView.noIntrinsicMetric : targetSize.width
        return CGSize(width: width, height: Self.preferredHeight(for: segmentedControl))
    }

    private static func preferredHeight(for segmentedControl: UISegmentedControl) -> CGFloat {
        let navigationBarHeight = UINavigationBar(frame: .zero)
            .sizeThatFits(CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            .height
        return max(segmentedControl.intrinsicContentSize.height, navigationBarHeight)
    }
}

#if DEBUG
extension NetworkDetailViewController {
    package var collectionViewForTesting: UICollectionView {
        collectionView
    }

    package var currentModeForTesting: NetworkDetailMode {
        mode
    }

    package var isDetailModeControlEnabledForTesting: Bool {
        modeSegmentedControl.isEnabled
    }

    package func isDetailModeEnabledForTesting(_ mode: NetworkDetailMode) -> Bool {
        modeSegmentedControl.isEnabledForSegment(at: modeIndex(for: mode))
    }

    package func selectModeForTesting(_ mode: NetworkDetailMode) {
        modeSegmentedControl.selectedSegmentIndex = modeIndex(for: mode)
        modeSegmentedControlValueChanged(modeSegmentedControl)
    }

    package func setModeForTesting(_ mode: NetworkDetailMode) {
        self.mode = mode
    }

    package func selectBodyLinkForTesting() {
        let indexPath = dataSource.indexPath(for: .bodyLink(mode.bodyRole))
        guard let indexPath, collectionView(collectionView, shouldSelectItemAt: indexPath) else {
            return
        }
        collectionView(collectionView, didSelectItemAt: indexPath)
    }
}
#endif

#Preview("Network Detail") {
    UINavigationController(
        rootViewController: NetworkDetailViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .detail)
        )
    )
}
#endif
