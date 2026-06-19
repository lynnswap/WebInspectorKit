#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
private final class NetworkResponseBodyFetchObservationBinding {
    private var observation: PortableObservationTracking.Token?
    private weak var request: NetworkRequest?
#if DEBUG
    private(set) var observationDelivery: PortableObservationTracking.Token?
#endif

    func bindIfNeeded(
        to request: NetworkRequest,
        handler: @escaping @MainActor (NetworkRequest) -> Void
    ) {
        guard self.request !== request else {
            return
        }

        cancel()
        self.request = request
        let token = withPortableContinuousObservation { [weak self, weak request] _ in
            guard let self,
                  let request,
                  self.request === request else {
                return
            }
            handler(request)
        }
        observation = token
#if DEBUG
        observationDelivery = token
#endif
    }

    func cancel() {
        observation?.cancel()
        observation = nil
        request = nil
#if DEBUG
        observationDelivery = nil
#endif
    }
}

@MainActor
package final class NetworkDetailViewController: UIViewController {
    private let model: NetworkPanelModel
    private var modelObservation: PortableObservationTracking.Token?
    private var selectedRequestRenderObservation: PortableObservationTracking.Token?
    private let responseBodyFetchObservationBinding = NetworkResponseBodyFetchObservationBinding()
    private let scrollEdgeController = NetworkDetailScrollEdgeController()
    private var isRenderingActive = false
    private var isBodyRenderingActive = false
    private lazy var bodyViewController = NetworkBodyViewController(
        scrollEdgeSink: scrollEdgeController
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
    private var previewRoles: [NetworkBody.Role] = []
    private var hasBoundSelectedRequest = false
    private weak var observedRequest: NetworkRequest?
    private var bodyTopToPreviewContainerConstraint: NSLayoutConstraint?
    private var bodyTopToPreviewRoleControlConstraint: NSLayoutConstraint?
#if DEBUG
    private var modelObservationDelivery: PortableObservationTracking.Token?
    private var selectedRequestRenderObservationDelivery: PortableObservationTracking.Token?
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
    fileprivate var mode: NetworkDetailViewController.Mode = .headers
    fileprivate var previewRole: NetworkBody.Role = .response

    package init(
        model: NetworkPanelModel,
        initialMode: NetworkDetailViewController.Mode = .headers
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
        modelObservation?.cancel()
        selectedRequestRenderObservation?.cancel()
        responseBodyFetchObservationBinding.cancel()
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
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        resumeRendering()
    }

    override package func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        suspendRendering()
    }

    override package func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        if edge == .top || edge == .bottom {
            return scrollEdgeController.contentScrollView ?? super.contentScrollView(for: edge)
        }
        return super.contentScrollView(for: edge)
    }

    package func discardDetailSurfaceAfterCompactRemoval() {
        clearSelectedRequestPresentation(discardReason: .compactRemoval)
    }

    private func startObservingModel() {
        guard isRenderingActive else {
            return
        }
        modelObservation?.cancel()
        let token = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            bindSelectedRequest(
                model.selectedRequest,
                force: selectedRequestRenderObservation == nil
            )
        }
        modelObservation = token
#if DEBUG
        modelObservationDelivery = token
#endif
    }

    private func resumeRendering() {
        guard isRenderingActive == false else {
            bindSelectedRequest(model.selectedRequest, force: selectedRequestRenderObservation == nil)
            updateBodyRenderingActiveForCurrentSurface()
            return
        }
        isRenderingActive = true
        bindSelectedRequest(model.selectedRequest, force: true)
        startObservingModel()
        updateBodyRenderingActiveForCurrentSurface()
    }

    private func suspendRendering() {
        guard isRenderingActive else {
            return
        }
        isRenderingActive = false
        modelObservation?.cancel()
        modelObservation = nil
        selectedRequestRenderObservation?.cancel()
        selectedRequestRenderObservation = nil
        unbindResponseBodyFetchObservation()
        setBodyRenderingActive(false)
#if DEBUG
        modelObservationDelivery = nil
        selectedRequestRenderObservationDelivery = nil
#endif
    }

    private func setBodyRenderingActive(_ isActive: Bool) {
        guard isBodyRenderingActive != isActive else {
            return
        }
        isBodyRenderingActive = isActive
        if isActive {
            bodyViewController.resumeRendering()
        } else {
            bodyViewController.suspendKeepingSurface()
        }
    }

    private func updateBodyRenderingActiveForCurrentSurface() {
        setBodyRenderingActive(isRenderingActive && previewContainerView.isHidden == false)
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

    private func bindSelectedRequest(_ request: NetworkRequest?, force: Bool = false) {
        guard isRenderingActive else {
            return
        }
        guard force || hasBoundSelectedRequest == false || observedRequest !== request else {
            renderModeControl(selectedRequest: request)
            return
        }

        guard let request else {
            clearSelectedRequestPresentation(discardReason: .emptySelection)
            return
        }

        hasBoundSelectedRequest = true
        selectedRequestRenderObservation?.cancel()
        selectedRequestRenderObservation = nil
        unbindResponseBodyFetchObservation()
        observedRequest = request
#if DEBUG
        selectedRequestRenderObservationDelivery = nil
#endif

        if contentUnavailableConfiguration != nil {
            contentUnavailableConfiguration = nil
        }
        renderModeControl(selectedRequest: request)
        bindSelectedRequestRendering(request)
    }

    private func rebindSelectedRequestRendering() {
        selectedRequestRenderObservation?.cancel()
        selectedRequestRenderObservation = nil
        unbindResponseBodyFetchObservation()
#if DEBUG
        selectedRequestRenderObservationDelivery = nil
#endif
        guard isRenderingActive else {
            return
        }
        guard let observedRequest else {
            return
        }
        bindSelectedRequestRendering(observedRequest)
    }

    private func bindSelectedRequestRendering(_ request: NetworkRequest) {
        guard isRenderingActive else {
            return
        }
        let token = withPortableContinuousObservation { [weak self, weak request] _ in
            guard let request,
                  self?.observedRequest === request else {
                return
            }
            self?.renderSelectedRequest(request)
        }
        selectedRequestRenderObservation = token
#if DEBUG
        selectedRequestRenderObservationDelivery = token
#endif
    }

    private func renderSelectedRequest(_ request: NetworkRequest) {
        guard isRenderingActive else {
            return
        }
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
        updateBodyRenderingActiveForCurrentSurface()
    }

    private func renderHeadersSurface(selectedRequest request: NetworkRequest) {
        title = request.displayName
        showHeaders()
        headersTextView.render(request: request)
    }

    private func setMode(_ nextMode: NetworkDetailViewController.Mode) {
        guard mode != nextMode else {
            renderModeControl()
            return
        }
        mode = nextMode
        guard isRenderingActive else {
            return
        }
        renderModeControl()
        rebindSelectedRequestRendering()
    }

    private func setPreviewRole(_ nextRole: NetworkBody.Role) {
        guard previewRole != nextRole else {
            renderPreviewRoleControl(
                roles: previewRoles,
                selectedRole: selectedPreviewRole(from: previewRoles)
            )
            return
        }
        previewRole = nextRole
        guard isRenderingActive else {
            return
        }
        rebindSelectedRequestRendering()
    }

    private func renderModeControl(selectedRequest request: NetworkRequest? = nil) {
        let request = request ?? observedRequest
        modeControlController.render(mode: mode, isEnabled: request != nil)
    }

    private func clearSelectedRequestPresentation(discardReason: NetworkBodyViewController.SurfaceDiscardReason) {
        hasBoundSelectedRequest = true
        selectedRequestRenderObservation?.cancel()
        selectedRequestRenderObservation = nil
        unbindResponseBodyFetchObservation()
        observedRequest = nil
#if DEBUG
        selectedRequestRenderObservationDelivery = nil
#endif
        title = nil
        showEmptySelection(discardReason: discardReason)
        renderModeControl(selectedRequest: nil)
    }

    private func showEmptySelection(discardReason: NetworkBodyViewController.SurfaceDiscardReason) {
        bodyViewController.discardSurface(reason: discardReason)
        setBodyRenderingActive(false)
        previewContainerView.isHidden = true
        headersTextView.isHidden = true
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
        setBodyRenderingActive(false)
        previewContainerView.isHidden = true
        scrollEdgeController.isPreviewRoleControlVisible = false
        bodyViewController.discardSurface(reason: .headersMode)
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
            bodyViewController.discardSurface(reason: .missingPreviewBody)
            unbindResponseBodyFetchObservation()
            return
        }
        bodyViewController.bindSurface(
            body: body(in: request, for: role),
            metadata: previewMetadata(in: request, for: role)
        )
        bindResponseBodyFetchObservationIfNeeded(for: request, role: role)
    }

    private func availablePreviewRoles(in request: NetworkRequest) -> [NetworkBody.Role] {
        var roles: [NetworkBody.Role] = []
        if request.requestBody != nil {
            roles.append(.request)
        }
        if request.responseBody != nil {
            roles.append(.response)
        }
        return roles
    }

    private func preferredPreviewRole(from roles: [NetworkBody.Role]) -> NetworkBody.Role? {
        roles.contains(.response) ? .response : roles.first
    }

    private func selectedPreviewRole(from roles: [NetworkBody.Role]) -> NetworkBody.Role? {
        roles.contains(previewRole) ? previewRole : preferredPreviewRole(from: roles)
    }

    private func renderPreviewRoleControl(
        roles: [NetworkBody.Role],
        selectedRole: NetworkBody.Role?
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
        role: NetworkBody.Role
    ) {
        guard isRenderingActive else {
            unbindResponseBodyFetchObservation()
            return
        }
        guard role == .response else {
            unbindResponseBodyFetchObservation()
            return
        }
        responseBodyFetchObservationBinding.bindIfNeeded(to: request) { [weak self] request in
            self?.fetchResponseBodyIfNeededForVisibleResponse(request)
        }
    }

    private func unbindResponseBodyFetchObservation() {
        responseBodyFetchObservationBinding.cancel()
    }

    private func fetchResponseBodyIfNeededForVisibleResponse(_ request: NetworkRequest) {
        guard isRenderingActive,
              mode == .preview,
              observedRequest === request,
              selectedPreviewRole(from: availablePreviewRoles(in: request)) == .response,
              request.canFetchResponseBody else {
            return
        }
        model.fetchResponseBodyIfNeeded(for: request)
    }

    private func body(in request: NetworkRequest, for role: NetworkBody.Role) -> NetworkBody? {
        switch role {
        case .request:
            request.requestBody
        case .response:
            request.responseBody
        }
    }

    private func previewMetadata(
        in request: NetworkRequest,
        for role: NetworkBody.Role
    ) -> NetworkBodyViewController.PreviewMetadata {
        switch role {
        case .request:
            return NetworkBodyViewController.PreviewMetadata(
                mimeType: mimeType(from: nil, headers: request.request.headers),
                url: request.request.url
            )
        case .response:
            return NetworkBodyViewController.PreviewMetadata(
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

    var currentModeForTesting: NetworkDetailViewController.Mode {
        mode
    }

    var currentPreviewRoleForTesting: NetworkBody.Role {
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

    var modelObservationDeliveryForTesting: PortableObservationTracking.Token? {
        modelObservationDelivery
    }

    var selectedRequestRenderObservationDeliveryForTesting: PortableObservationTracking.Token? {
        selectedRequestRenderObservationDelivery
    }

    var responseBodyFetchObservationDeliveryForTesting: PortableObservationTracking.Token? {
        responseBodyFetchObservationBinding.observationDelivery
    }

    func isDetailModeEnabledForTesting(_ mode: NetworkDetailViewController.Mode) -> Bool {
        modeControlController.isModeEnabledForTesting(mode)
    }

    func selectModeForTesting(_ mode: NetworkDetailViewController.Mode) {
        modeControlController.selectModeForTesting(mode)
    }

    func setModeForTesting(_ mode: NetworkDetailViewController.Mode) {
        setMode(mode)
    }

    func selectPreviewRoleForTesting(_ role: NetworkBody.Role) {
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
