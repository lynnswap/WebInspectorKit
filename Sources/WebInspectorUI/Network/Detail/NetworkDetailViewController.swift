#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class NetworkDetailViewController: UIViewController {
    private let model: NetworkPanelModel
    private let modelObservationScope = ObservationScope()
    private let selectedRequestRenderObservationScope = ObservationScope()
    private let responseBodyFetchObservationScope = ObservationScope()
    private let scrollEdgeController = NetworkDetailScrollEdgeController()
    private lazy var bodyViewController = NetworkBodyViewController(
        scrollEdgeState: scrollEdgeController.scrollEdgeState
    )
    private lazy var modeControlController: NetworkDetailModeControlController = {
        let controller = NetworkDetailModeControlController(initialMode: mode)
        controller.selectionHandler = { [weak self] mode in
            self?.setMode(mode)
        }
        return controller
    }()
    private lazy var previewRoleControlController: NetworkPreviewRoleControlController = {
        let controller = NetworkPreviewRoleControlController()
        controller.selectionHandler = { [weak self] role in
            self?.setPreviewRole(role)
        }
        return controller
    }()
    private var previewRoles: [NetworkBodyRole] = []
    private var hasBoundSelectedRequest = false
    private weak var observedRequest: NetworkRequest?
    private weak var responseBodyFetchRequest: NetworkRequest?
    private var bodyTopToPreviewContainerConstraint: NSLayoutConstraint?
    private var bodyTopToPreviewRoleControlConstraint: NSLayoutConstraint?
#if DEBUG
    private var modelObservationDelivery: ObservationDelivery?
    private var selectedRequestRenderObservationDelivery: ObservationDelivery?
    private var responseBodyFetchObservationDelivery: ObservationDelivery?
#endif
    private lazy var previewContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.accessibilityIdentifier = "WebInspector.Network.DetailPreview"
        return view
    }()
    private lazy var headersTextView: NetworkHeadersTextView = {
        let view = NetworkHeadersTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    fileprivate var mode: NetworkDetailMode = .headers
    fileprivate var previewRole: NetworkBodyRole = .response

    package init(
        model: NetworkPanelModel,
        initialMode: NetworkDetailMode = .headers
    ) {
        self.model = model
        mode = initialMode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        modelObservationScope.cancelAll()
        selectedRequestRenderObservationScope.cancelAll()
        responseBodyFetchObservationScope.cancelAll()
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
        installModeTitleView()
        scrollEdgeController.install(previewRoleControlContainerView: previewRoleControlController.containerView)
        startObservingModel()
    }

    override package func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        if edge == .top || edge == .bottom {
            return scrollEdgeController.contentScrollView ?? super.contentScrollView(for: edge)
        }
        return super.contentScrollView(for: edge)
    }

    private func startObservingModel() {
        let delivery = modelObservationScope.observe(model) { [weak self] _, model in
            self?.bindSelectedRequest(model.selectedRequest)
        }
#if DEBUG
        modelObservationDelivery = delivery
#endif
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        bodyViewController.view.backgroundColor = backgroundColor
        headersTextView.backgroundColor = backgroundColor
    }

    private func installContentViews() {
        addChild(bodyViewController)
        view.addSubview(previewContainerView)
        view.addSubview(headersTextView)
        bodyViewController.view.translatesAutoresizingMaskIntoConstraints = false
        previewRoleControlController.containerView.translatesAutoresizingMaskIntoConstraints = false
        previewContainerView.addSubview(bodyViewController.view)
        previewContainerView.addSubview(previewRoleControlController.containerView)
        bodyViewController.didMove(toParent: self)

        let bodyTopToPreviewContainerConstraint = bodyViewController.view.topAnchor.constraint(
            equalTo: previewContainerView.topAnchor
        )
        let bodyTopToPreviewRoleControlConstraint = bodyViewController.view.topAnchor.constraint(
            equalTo: previewRoleControlController.containerView.bottomAnchor
        )
        self.bodyTopToPreviewContainerConstraint = bodyTopToPreviewContainerConstraint
        self.bodyTopToPreviewRoleControlConstraint = bodyTopToPreviewRoleControlConstraint
        bodyTopToPreviewContainerConstraint.isActive = true

        NSLayoutConstraint.activate([
            previewContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            previewContainerView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            previewContainerView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            previewContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bodyViewController.view.leadingAnchor.constraint(equalTo: previewContainerView.leadingAnchor),
            bodyViewController.view.trailingAnchor.constraint(equalTo: previewContainerView.trailingAnchor),
            bodyViewController.view.bottomAnchor.constraint(equalTo: previewContainerView.bottomAnchor),
            previewRoleControlController.containerView.topAnchor.constraint(equalTo: previewContainerView.safeAreaLayoutGuide.topAnchor),
            previewRoleControlController.containerView.leadingAnchor.constraint(equalTo: previewContainerView.leadingAnchor),
            previewRoleControlController.containerView.trailingAnchor.constraint(equalTo: previewContainerView.trailingAnchor),
            headersTextView.topAnchor.constraint(equalTo: view.topAnchor),
            headersTextView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            headersTextView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            headersTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func updatePreviewRoleControlLayout(isVisible: Bool) {
        if #available(iOS 26.0, *) {
            bodyTopToPreviewRoleControlConstraint?.isActive = false
            bodyTopToPreviewContainerConstraint?.isActive = true
        } else {
            bodyTopToPreviewContainerConstraint?.isActive = isVisible == false
            bodyTopToPreviewRoleControlConstraint?.isActive = isVisible
        }
    }

    private func installModeTitleView() {
        navigationItem.titleView = modeControlController.view
        renderModeControl()
    }

    private func bindSelectedRequest(_ request: NetworkRequest?) {
        guard hasBoundSelectedRequest == false || observedRequest !== request else {
            renderModeControl(selectedRequest: request)
            return
        }

        hasBoundSelectedRequest = true
        selectedRequestRenderObservationScope.cancelAll()
        unbindResponseBodyFetchObservation()
        observedRequest = request
#if DEBUG
        selectedRequestRenderObservationDelivery = nil
#endif

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
        bindSelectedRequestRendering(request)
    }

    private func rebindSelectedRequestRendering() {
        selectedRequestRenderObservationScope.cancelAll()
        unbindResponseBodyFetchObservation()
#if DEBUG
        selectedRequestRenderObservationDelivery = nil
#endif
        guard let observedRequest else {
            return
        }
        bindSelectedRequestRendering(observedRequest)
    }

    private func bindSelectedRequestRendering(_ request: NetworkRequest) {
        let delivery = selectedRequestRenderObservationScope.observe(request) { [weak self] _, request in
            guard self?.observedRequest === request else {
                return
            }
            self?.renderSelectedRequest(request)
        }
#if DEBUG
        selectedRequestRenderObservationDelivery = delivery
#endif
    }

    private func renderSelectedRequest(_ request: NetworkRequest) {
        switch mode {
        case .preview:
            renderPreviewSurface(selectedRequest: request)
        case .headers:
            renderHeadersSurface(selectedRequest: request)
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

    private func setMode(_ nextMode: NetworkDetailMode) {
        guard mode != nextMode else {
            renderModeControl()
            return
        }
        mode = nextMode
        renderModeControl()
        rebindSelectedRequestRendering()
    }

    private func setPreviewRole(_ nextRole: NetworkBodyRole) {
        guard previewRole != nextRole else {
            renderPreviewRoleControl(
                roles: previewRoles,
                selectedRole: selectedPreviewRole(from: previewRoles)
            )
            return
        }
        previewRole = nextRole
        rebindSelectedRequestRendering()
    }

    private func renderModeControl(selectedRequest request: NetworkRequest? = nil) {
        let request = request ?? observedRequest
        modeControlController.render(mode: mode, isEnabled: request != nil)
    }

    private func showEmptySelection() {
        previewContainerView.isHidden = true
        headersTextView.isHidden = true
        bodyViewController.display(body: nil)
        headersTextView.clear()
        renderPreviewRoleControl(roles: [], selectedRole: nil)
        scrollEdgeController.contentScrollView = nil

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
        previewContainerView.isHidden = false
    }

    private func showHeaders() {
        previewContainerView.isHidden = true
        scrollEdgeController.isPreviewRoleControlVisible = false
        bodyViewController.releasePreviewResources()
        headersTextView.isHidden = false
        scrollEdgeController.contentScrollView = headersTextView.contentScrollView
    }

    private func renderPreview(selectedRequest request: NetworkRequest) {
        let roles = availablePreviewRoles(in: request)
        let selectedRole = selectedPreviewRole(from: roles)
        if let selectedRole, selectedRole != previewRole {
            previewRole = selectedRole
        }
        renderPreviewRoleControl(roles: roles, selectedRole: selectedRole)

        guard let role = selectedRole else {
            bodyViewController.display(body: nil)
            unbindResponseBodyFetchObservation()
            return
        }
        bodyViewController.display(
            body: body(in: request, for: role),
            metadata: previewMetadata(in: request, for: role)
        )
        bindResponseBodyFetchObservationIfNeeded(for: request, role: role)
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

    private func selectedPreviewRole(from roles: [NetworkBodyRole]) -> NetworkBodyRole? {
        roles.contains(previewRole) ? previewRole : preferredPreviewRole(from: roles)
    }

    private func renderPreviewRoleControl(
        roles: [NetworkBodyRole],
        selectedRole: NetworkBodyRole?
    ) {
        previewRoles = roles
        let isControlVisible = roles.count >= 2
        let isVisibleInPreview = isControlVisible && previewContainerView.isHidden == false
        previewRoleControlController.render(
            roles: roles,
            selectedRole: selectedRole,
            isVisible: isVisibleInPreview
        )
        updatePreviewRoleControlLayout(isVisible: isVisibleInPreview)
        scrollEdgeController.isPreviewRoleControlVisible = isVisibleInPreview
    }

    private func bindResponseBodyFetchObservationIfNeeded(
        for request: NetworkRequest,
        role: NetworkBodyRole
    ) {
        guard role == .response else {
            unbindResponseBodyFetchObservation()
            return
        }
        guard responseBodyFetchRequest !== request else {
            return
        }

        responseBodyFetchObservationScope.cancelAll()
        responseBodyFetchRequest = request
        let delivery = responseBodyFetchObservationScope.observe(request) { [weak self] _, request in
            guard self?.responseBodyFetchRequest === request else {
                return
            }
            self?.fetchResponseBodyIfNeededForVisibleResponse(request)
        }
#if DEBUG
        responseBodyFetchObservationDelivery = delivery
#endif
    }

    private func unbindResponseBodyFetchObservation() {
        responseBodyFetchObservationScope.cancelAll()
        responseBodyFetchRequest = nil
#if DEBUG
        responseBodyFetchObservationDelivery = nil
#endif
    }

    private func fetchResponseBodyIfNeededForVisibleResponse(_ request: NetworkRequest) {
        guard mode == .preview,
              observedRequest === request,
              selectedPreviewRole(from: availablePreviewRoles(in: request)) == .response,
              request.canFetchResponseBody else {
            return
        }
        model.fetchResponseBodyIfNeeded(for: request)
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

}

#if DEBUG
extension NetworkDetailViewController {
    var previewViewForTesting: UIView {
        previewContainerView
    }

    var previewRoleControlContainerViewForTesting: UIView {
        previewRoleControlController.containerView
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
        modeControlController.isEnabledForTesting
    }

    var isPreviewRoleControlHiddenForTesting: Bool {
        previewRoleControlController.isHiddenForTesting
    }

    @available(iOS 26.0, *)
    var previewRoleScrollEdgeInteractionForTesting: UIScrollEdgeElementContainerInteraction? {
        scrollEdgeController.interactionForTesting
    }

    var previewRoleScrollEdgeObservationDeliveryForTesting: ObservationDelivery? {
        scrollEdgeController.observationDeliveryForTesting
    }

    var modelObservationDeliveryForTesting: ObservationDelivery? {
        modelObservationDelivery
    }

    var selectedRequestRenderObservationDeliveryForTesting: ObservationDelivery? {
        selectedRequestRenderObservationDelivery
    }

    var responseBodyFetchObservationDeliveryForTesting: ObservationDelivery? {
        responseBodyFetchObservationDelivery
    }

    func isDetailModeEnabledForTesting(_ mode: NetworkDetailMode) -> Bool {
        modeControlController.isModeEnabledForTesting(mode)
    }

    func selectModeForTesting(_ mode: NetworkDetailMode) {
        modeControlController.selectModeForTesting(mode)
    }

    func setModeForTesting(_ mode: NetworkDetailMode) {
        setMode(mode)
    }

    func selectPreviewRoleForTesting(_ role: NetworkBodyRole) {
        previewRoleControlController.selectRoleForTesting(role)
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
