#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import SyntaxEditorUI
import UIKit

@MainActor
package final class NetworkDetailViewController: UIViewController, UICollectionViewDelegate {
    private struct HeaderField: Hashable {
        var name: String
        var value: String
    }

    private enum SectionIdentifier: Int, CaseIterable, Hashable {
        case overview
        case request
        case response

        var title: String {
            switch self {
            case .overview:
                String(localized: "network.detail.section.overview", bundle: .module)
            case .request:
                String(localized: "network.section.request", bundle: .module)
            case .response:
                String(localized: "network.section.response", bundle: .module)
            }
        }
    }

    private enum ItemIdentifier: Hashable {
        case overview(NetworkRequest.ID)
        case requestHeader(HeaderField)
        case requestHeadersEmpty
        case responseHeader(HeaderField)
        case responseHeadersEmpty
    }

    private let model: NetworkPanelModel
    private let observationScope = ObservationScope()
    private let bodyViewController = NetworkBodyViewController()
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
    fileprivate var mode: NetworkDetailMode = .overview {
        didSet {
            guard mode != oldValue else {
                return
            }
            renderCurrentMode(reloadData: mode == .overview)
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
        installBodyViewController()
        installModePalette()
        startObservingModel()
    }

    package func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
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

    private func installBodyViewController() {
        addChild(bodyViewController)
        bodyViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bodyViewController.view)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bodyViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            bodyViewController.view.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            bodyViewController.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            bodyViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        bodyViewController.didMove(toParent: self)
        bodyViewController.view.isHidden = true
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
        let overviewCellRegistration = UICollectionView.CellRegistration<NetworkOverviewCell, NetworkRequest> {
            cell, _, request in
            cell.bind(request: request)
        }
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
            configuration.text = section.title
            header.contentConfiguration = configuration
        }

        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else {
                return nil
            }
            if case .overview = item, let selectedRequest = self.selectedRequest {
                return collectionView.dequeueConfiguredReusableCell(
                    using: overviewCellRegistration,
                    for: indexPath,
                    item: selectedRequest
                )
            }
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
        renderCurrentMode(reloadData: reloadData)
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
        case .overview:
            return true
        case .requestBody:
            return request.requestBody != nil
        case .responseBody:
            return request.responseBody != nil
        }
    }

    private func modeIndex(for mode: NetworkDetailMode) -> Int {
        NetworkDetailMode.allCases.firstIndex(of: mode) ?? UISegmentedControl.noSegment
    }

    private func renderCurrentMode(reloadData: Bool) {
        guard isViewLoaded else {
            return
        }
        guard let selectedRequest else {
            return
        }
        guard resetUnavailableModeIfNeeded(for: selectedRequest) == false else {
            return
        }

        switch mode {
        case .overview:
            showOverview()
            if reloadData {
                applySnapshotUsingReloadData()
            } else {
                applySnapshot()
            }
        case .requestBody, .responseBody:
            guard let role = mode.bodyRole else {
                return
            }
            let body = body(in: selectedRequest, for: role)
            showBody()
            bodyViewController.display(body: body)
            if role == .response {
                model.fetchResponseBodyIfNeeded(for: selectedRequest)
            }
        }
    }

    private func showEmptySelection() {
        if collectionView.isHidden == false {
            collectionView.isHidden = true
        }
        if bodyViewController.view.isHidden == false {
            bodyViewController.view.isHidden = true
        }
        bodyViewController.display(body: nil)
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

    private func showOverview() {
        if bodyViewController.view.isHidden == false {
            bodyViewController.view.isHidden = true
        }
        if collectionView.isHidden {
            collectionView.isHidden = false
        }
        bodyViewController.display(body: nil)
    }

    private func showBody() {
        if collectionView.isHidden == false {
            collectionView.isHidden = true
        }
        if bodyViewController.view.isHidden {
            bodyViewController.view.isHidden = false
        }
    }

    private func resetUnavailableModeIfNeeded(for request: NetworkRequest) -> Bool {
        guard let role = mode.bodyRole else {
            return false
        }
        guard body(in: request, for: role) == nil else {
            return false
        }
        mode = .overview
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

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        guard let selectedRequest else {
            return NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        }

        let requestHeaders = headerFields(from: selectedRequest.request.headers)
        let responseHeaders = headerFields(from: selectedRequest.response?.headers ?? [:])
        let requestItems: [ItemIdentifier] = requestHeaders.isEmpty
            ? [.requestHeadersEmpty]
            : requestHeaders.map { .requestHeader($0) }
        let responseItems: [ItemIdentifier] = responseHeaders.isEmpty
            ? [.responseHeadersEmpty]
            : responseHeaders.map { .responseHeader($0) }

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        snapshot.appendSections(SectionIdentifier.allCases)
        snapshot.appendItems([.overview(selectedRequest.id)], toSection: .overview)
        snapshot.appendItems(requestItems, toSection: .request)
        snapshot.appendItems(responseItems, toSection: .response)
        return snapshot
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

    private func applySnapshot() {
        guard isViewLoaded else {
            return
        }
        let snapshot = makeSnapshot()
        let currentSnapshot = dataSource.snapshot()
        guard currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers else {
            return
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applySnapshotUsingReloadData() {
        guard isViewLoaded else {
            return
        }
        let snapshot = makeSnapshot()
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
        case .overview:
            cell.clear()
        case .requestHeader(let field), .responseHeader(let field):
            cell.bindHeader(name: field.name, value: field.value)
        case .requestHeadersEmpty, .responseHeadersEmpty:
            cell.bindEmptyHeaders()
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

    package var bodyTextViewForTesting: SyntaxEditorView {
        bodyViewController.syntaxViewForTesting
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
