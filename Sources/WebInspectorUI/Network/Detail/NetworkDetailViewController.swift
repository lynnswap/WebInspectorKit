#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class NetworkDetailViewController: UIViewController {
    private let model: NetworkPanelModel
    private let modelObservationScope = ObservationScope()
    private let selectedRequestSurfaceObservationScope = ObservationScope()
    private let bodyViewController = NetworkBodyViewController()
    private var modePalette: UIView?
    private var previewRoles: [NetworkBodyRole] = []
    private var hasBoundSelectedRequest = false
    private weak var observedRequest: NetworkRequest?
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
    private lazy var previewRoleSegmentedControl: UISegmentedControl = {
        let control = UISegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.accessibilityIdentifier = "WebInspector.Network.DetailPreviewRoleSegmentedControl"
        control.addTarget(self, action: #selector(previewRoleSegmentedControlValueChanged(_:)), for: .valueChanged)
        return control
    }()
    private lazy var previewRoleControlContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.preservesSuperviewLayoutMargins = true
        view.addSubview(previewRoleSegmentedControl)
        NSLayoutConstraint.activate([
            previewRoleSegmentedControl.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            previewRoleSegmentedControl.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            previewRoleSegmentedControl.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            previewRoleSegmentedControl.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor),
        ])
        return view
    }()
    private lazy var previewStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [
            previewRoleControlContainer,
            bodyViewController.view,
        ])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 0
        stackView.isHidden = true
        stackView.accessibilityIdentifier = "WebInspector.Network.DetailPreview"
        return stackView
    }()
    private lazy var headersTextView: NetworkHeadersTextView = {
        let view = NetworkHeadersTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    fileprivate var mode: NetworkDetailMode = .preview {
        didSet {
            guard mode != oldValue else {
                return
            }
            bindCurrentModeSurface()
            renderModeControl(selectedRequest: observedRequest)
        }
    }
    fileprivate var previewRole: NetworkBodyRole = .response {
        didSet {
            guard previewRole != oldValue else {
                return
            }
            if let observedRequest, mode == .preview {
                renderPreviewSurface(selectedRequest: observedRequest)
            }
        }
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
        modelObservationScope.cancelAll()
        selectedRequestSurfaceObservationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        installContentViews()
        installModePalette()
        startObservingModel()
    }

    private func startObservingModel() {
        modelObservationScope.observe(model) { [weak self] _, model in
            self?.bindSelectedRequest(model.selectedRequest)
        }
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        previewRoleControlContainer.backgroundColor = backgroundColor
        bodyViewController.view.backgroundColor = backgroundColor
        headersTextView.backgroundColor = backgroundColor
    }

    private func installContentViews() {
        addChild(bodyViewController)
        view.addSubview(previewStackView)
        view.addSubview(headersTextView)
        bodyViewController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            previewStackView.topAnchor.constraint(equalTo: view.topAnchor),
            previewStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewStackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            headersTextView.topAnchor.constraint(equalTo: view.topAnchor),
            headersTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headersTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headersTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

    private func bindSelectedRequest(_ request: NetworkRequest?) {
        guard hasBoundSelectedRequest == false || observedRequest !== request else {
            renderModeControl(selectedRequest: request)
            return
        }

        hasBoundSelectedRequest = true
        selectedRequestSurfaceObservationScope.cancelAll()
        observedRequest = request

        guard let request else {
            title = nil
            showEmptySelection()
            renderModeControl(selectedRequest: nil)
            return
        }

        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        renderModeControl(selectedRequest: request)
        bindCurrentModeSurface()
    }

    private func bindCurrentModeSurface() {
        selectedRequestSurfaceObservationScope.cancelAll()
        guard let request = observedRequest else {
            return
        }

        switch mode {
        case .preview:
            selectedRequestSurfaceObservationScope.observe(request, tracking: { request in
                _ = request.request
                _ = request.requestBody
                _ = request.response
                _ = request.responseBody
                _ = request.state
            }) { [weak self] _, request in
                self?.renderPreviewSurface(selectedRequest: request)
            }
        case .headers:
            selectedRequestSurfaceObservationScope.observe(request, tracking: { request in
                _ = request.request
                _ = request.response
                _ = request.metrics
            }) { [weak self] _, request in
                self?.renderHeadersSurface(selectedRequest: request)
            }
        }
    }

    private func renderPreviewSurface(selectedRequest request: NetworkRequest) {
        title = request.displayName
        showPreview()
        renderPreview(selectedRequest: request)
    }

    private func renderHeadersSurface(selectedRequest request: NetworkRequest) {
        title = request.displayName
        showHeaders()
        headersTextView.render(request: request)
    }

    @objc private func modeSegmentedControlValueChanged(_ sender: UISegmentedControl) {
        guard NetworkDetailMode.allCases.indices.contains(sender.selectedSegmentIndex) else {
            renderModeControl()
            return
        }
        mode = NetworkDetailMode.allCases[sender.selectedSegmentIndex]
    }

    @objc private func previewRoleSegmentedControlValueChanged(_ sender: UISegmentedControl) {
        guard previewRoles.indices.contains(sender.selectedSegmentIndex) else {
            renderPreviewRoleControl()
            return
        }
        previewRole = previewRoles[sender.selectedSegmentIndex]
    }

    private func renderModeControl(selectedRequest request: NetworkRequest? = nil) {
        let request = request ?? observedRequest
        modeSegmentedControl.isEnabled = request != nil
        modeSegmentedControl.selectedSegmentIndex = modeIndex(for: mode)
        modeSegmentedControl.accessibilityLabel = mode.title
        for index in NetworkDetailMode.allCases.indices {
            modeSegmentedControl.setEnabled(request != nil, forSegmentAt: index)
        }
    }

    private func modeIndex(for mode: NetworkDetailMode) -> Int {
        NetworkDetailMode.allCases.firstIndex(of: mode) ?? UISegmentedControl.noSegment
    }

    private func showEmptySelection() {
        previewStackView.isHidden = true
        headersTextView.isHidden = true
        bodyViewController.display(body: nil)
        headersTextView.clear()
        previewRoles = []
        renderPreviewRoleControl()

        if let configuration = contentUnavailableConfiguration as? UIContentUnavailableConfiguration,
           configuration.text == String(localized: "network.empty.selection.title", bundle: .module) {
            return
        }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = String(localized: "network.empty.selection.title", bundle: .module)
        configuration.textProperties.color = .secondaryLabel
        contentUnavailableConfiguration = configuration
    }

    private func showPreview() {
        headersTextView.isHidden = true
        previewStackView.isHidden = false
    }

    private func showHeaders() {
        previewStackView.isHidden = true
        headersTextView.isHidden = false
    }

    private func renderPreview(selectedRequest request: NetworkRequest) {
        let roles = availablePreviewRoles(in: request)
        previewRoles = roles
        if let preferredRole = preferredPreviewRole(from: roles), roles.contains(previewRole) == false {
            previewRole = preferredRole
            return
        }
        renderPreviewRoleControl()

        guard let role = roles.contains(previewRole) ? previewRole : roles.first else {
            bodyViewController.display(body: nil)
            return
        }
        bodyViewController.display(
            body: body(in: request, for: role),
            metadata: previewMetadata(in: request, for: role)
        )
        if role == .response {
            model.fetchResponseBodyIfNeeded(for: request)
        }
    }

    private func availablePreviewRoles(in request: NetworkRequest) -> [NetworkBodyRole] {
        var roles: [NetworkBodyRole] = []
        if request.requestBody != nil {
            roles.append(.request)
        }
        if request.responseBody != nil {
            roles.append(.response)
        }
        return roles
    }

    private func preferredPreviewRole(from roles: [NetworkBodyRole]) -> NetworkBodyRole? {
        roles.contains(.response) ? .response : roles.first
    }

    private func renderPreviewRoleControl() {
        previewRoleSegmentedControl.removeAllSegments()
        for (index, role) in previewRoles.enumerated() {
            previewRoleSegmentedControl.insertSegment(
                withTitle: title(for: role),
                at: index,
                animated: false
            )
        }
        previewRoleControlContainer.isHidden = previewRoles.count < 2
        previewRoleSegmentedControl.selectedSegmentIndex = previewRoles.firstIndex(of: previewRole)
            ?? UISegmentedControl.noSegment
        previewRoleSegmentedControl.accessibilityLabel = previewRoles.contains(previewRole) ? title(for: previewRole) : nil
    }

    private func body(in request: NetworkRequest, for role: NetworkBodyRole) -> NetworkBody? {
        switch role {
        case .request:
            request.requestBody
        case .response:
            request.responseBody
        }
    }

    private func previewMetadata(
        in request: NetworkRequest,
        for role: NetworkBodyRole
    ) -> NetworkBodyPreviewMetadata {
        switch role {
        case .request:
            return NetworkBodyPreviewMetadata(
                mimeType: mimeType(from: nil, headers: request.request.headers),
                url: request.request.url
            )
        case .response:
            return NetworkBodyPreviewMetadata(
                mimeType: mimeType(from: request.response?.mimeType, headers: request.response?.headers ?? [:]),
                url: request.response?.url ?? request.request.url
            )
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

    private func title(for role: NetworkBodyRole) -> String {
        switch role {
        case .request:
            String(localized: "network.section.request", bundle: .module)
        case .response:
            String(localized: "network.section.response", bundle: .module)
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
    var previewViewForTesting: UIView {
        previewStackView
    }

    var headersTextViewForTesting: NetworkHeadersTextView {
        headersTextView
    }

    var bodyViewControllerForTesting: NetworkBodyViewController {
        bodyViewController
    }

    var currentModeForTesting: NetworkDetailMode {
        mode
    }

    var currentPreviewRoleForTesting: NetworkBodyRole {
        previewRole
    }

    var isDetailModeControlEnabledForTesting: Bool {
        modeSegmentedControl.isEnabled
    }

    var isPreviewRoleControlHiddenForTesting: Bool {
        previewRoleControlContainer.isHidden
    }

    func isDetailModeEnabledForTesting(_ mode: NetworkDetailMode) -> Bool {
        modeSegmentedControl.isEnabledForSegment(at: modeIndex(for: mode))
    }

    func selectModeForTesting(_ mode: NetworkDetailMode) {
        modeSegmentedControl.selectedSegmentIndex = modeIndex(for: mode)
        modeSegmentedControlValueChanged(modeSegmentedControl)
    }

    func setModeForTesting(_ mode: NetworkDetailMode) {
        self.mode = mode
    }

    func selectPreviewRoleForTesting(_ role: NetworkBodyRole) {
        previewRoleSegmentedControl.selectedSegmentIndex = previewRoles.firstIndex(of: role)
            ?? UISegmentedControl.noSegment
        previewRoleSegmentedControlValueChanged(previewRoleSegmentedControl)
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
