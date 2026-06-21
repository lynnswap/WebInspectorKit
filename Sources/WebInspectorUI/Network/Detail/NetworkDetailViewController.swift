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
        clearSelectedRequestPresentation(bodySurface: .none)
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
        setBodyRenderingActive(isRenderingActive && bodyViewController.view.isHidden == false)
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        bodyViewController.view.backgroundColor = backgroundColor
        headersTextView.backgroundColor = backgroundColor
    }

    private func installContentViews() {
        addChild(bodyViewController)
        view.addSubview(bodyViewController.view)
        view.addSubview(previewRoleControlController.containerView)
        view.addSubview(headersTextView)
        bodyViewController.view.translatesAutoresizingMaskIntoConstraints = false
        bodyViewController.view.isHidden = true
        bodyViewController.view.accessibilityIdentifier = "WebInspector.Network.DetailPreview"
        previewRoleControlController.containerView.translatesAutoresizingMaskIntoConstraints = false
        bodyViewController.didMove(toParent: self)

        let bodyTopToPreviewContainerConstraint = bodyViewController.view.topAnchor.constraint(
            equalTo: view.topAnchor
        )
        let bodyTopToPreviewRoleControlConstraint = bodyViewController.view.topAnchor.constraint(
            equalTo: previewRoleControlController.containerView.bottomAnchor
        )
        self.bodyTopToPreviewContainerConstraint = bodyTopToPreviewContainerConstraint
        self.bodyTopToPreviewRoleControlConstraint = bodyTopToPreviewRoleControlConstraint
        bodyTopToPreviewContainerConstraint.isActive = true

        NSLayoutConstraint.activate([
            bodyViewController.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bodyViewController.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            bodyViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewRoleControlController.containerView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),
            previewRoleControlController.containerView.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor
            ),
            previewRoleControlController.containerView.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor
            ),
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
            let topInset = isVisible
                ? previewRoleControlController.containerView.systemLayoutSizeFitting(
                    UIView.layoutFittingCompressedSize
                ).height
                : 0
            if bodyViewController.additionalSafeAreaInsets.top != topInset {
                bodyViewController.additionalSafeAreaInsets.top = topInset
            }
        } else {
            if bodyViewController.additionalSafeAreaInsets.top != 0 {
                bodyViewController.additionalSafeAreaInsets.top = 0
            }
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
            clearSelectedRequestPresentation(bodySurface: .none)
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

    private func clearSelectedRequestPresentation(bodySurface: NetworkBodyViewController.Surface) {
        hasBoundSelectedRequest = true
        selectedRequestRenderObservation?.cancel()
        selectedRequestRenderObservation = nil
        unbindResponseBodyFetchObservation()
        observedRequest = nil
#if DEBUG
        selectedRequestRenderObservationDelivery = nil
#endif
        title = nil
        showEmptySelection(bodySurface: bodySurface)
        renderModeControl(selectedRequest: nil)
    }

    private func showEmptySelection(bodySurface: NetworkBodyViewController.Surface) {
        bodyViewController.setSurface(bodySurface)
        setBodyRenderingActive(false)
        bodyViewController.view.isHidden = true
        previewRoleControlController.containerView.isHidden = true
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
        bodyViewController.view.isHidden = false
    }

    private func showHeaders() {
        setBodyRenderingActive(false)
        bodyViewController.view.isHidden = true
        previewRoleControlController.containerView.isHidden = true
        updatePreviewRoleControlLayout(isVisible: false)
        scrollEdgeController.isPreviewRoleControlVisible = false
        bodyViewController.setSurface(.none)
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
            bodyViewController.setSurface(.unavailableBodyPlaceholder)
            unbindResponseBodyFetchObservation()
            return
        }
        bodyViewController.setSurface(bodySurface(in: request, for: role))
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
        let isVisibleInPreview = isControlVisible && bodyViewController.view.isHidden == false
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

    private func bodySurface(
        in request: NetworkRequest,
        for role: NetworkBody.Role
    ) -> NetworkBodyViewController.Surface {
        guard let body = body(in: request, for: role) else {
            return .unavailableBodyPlaceholder
        }
        return .body(
            body,
            metadata: previewMetadata(in: request, for: role)
        )
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
        bodyViewController.view
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

#Preview("Network Detail Preview Response Only Short") {
    UINavigationController(
        rootViewController: NetworkDetailViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .detailResponseOnlyShort),
            initialMode: .preview
        )
    )
}

#Preview("Network Detail Preview Request and Response Short") {
    UINavigationController(
        rootViewController: NetworkDetailViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .detailRequestAndResponseShort),
            initialMode: .preview
        )
    )
}

#Preview("Network Detail Preview Response Only Long") {
    UINavigationController(
        rootViewController: NetworkDetailViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .detailResponseOnlyLong),
            initialMode: .preview
        )
    )
}

#Preview("Network Detail Preview Request and Response Long") {
    UINavigationController(
        rootViewController: NetworkDetailViewController(
            model: NetworkPreviewFixtures.makePanelModel(mode: .detailRequestAndResponseLong),
            initialMode: .preview
        )
    )
}
#endif
