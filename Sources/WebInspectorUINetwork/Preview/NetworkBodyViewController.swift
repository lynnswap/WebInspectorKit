#if canImport(UIKit)
import AVFoundation
import AVKit
import WebInspectorDataKit
import WebInspectorUIBase
import Observation
import ObservationBridge
import SyntaxEditorUI
import UIKit

extension NetworkBodyViewController {
    typealias PreviewMetadata = NetworkMediaPreviewMetadata
}

@MainActor
package final class NetworkBodyViewController: UIViewController, NetworkBodyPreviewControlling {
    package typealias MoviePreviewPlayerFactory = @MainActor () -> AVPlayer

    private let syntaxModel = SyntaxEditorModel(
        text: "",
        language: .json,
        isEditable: false,
        lineWrappingEnabled: true,
        theme: .default,
        drawsBackground: false
    )
    private var syntaxViewStorage: SyntaxEditorView?
    private var syntaxView: SyntaxEditorView {
        if let syntaxViewStorage {
            return syntaxViewStorage
        }
        let view = SyntaxEditorView(model: syntaxModel)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .automatic
        view.keyboardDismissMode = .onDrag
        view.accessibilityIdentifier = "WebInspector.Network.BodyView"
        syntaxViewStorage = view
        return view
    }
    private lazy var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = .clear
        imageView.accessibilityIdentifier = "WebInspector.Network.BodyImagePreview"
        return imageView
    }()
    private lazy var imageScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.contentAlignmentPoint = CGPoint(x: 0.5, y: 0.5)
        scrollView.delegate = self
        scrollView.isHidden = true
        scrollView.maximumZoomScale = 1
        scrollView.minimumZoomScale = 1
        scrollView.accessibilityIdentifier = "WebInspector.Network.BodyImageScrollView"
        scrollView.addSubview(imageView)
        return scrollView
    }()
    private var bodyObservation: PortableObservationTracking.Token?
    private weak var scrollEdgeSink: (any NetworkBodyScrollEdgeSink)?
    private var surface = NetworkBodySurface.none
    private var isRenderingActive = false
    private var mediaPlayerViewController: AVPlayerViewController?
    private var mediaPlayerSurfaceBodyID: ObjectIdentifier?
    private var mediaPlayerStatusView: UIContentUnavailableView?
    private var mediaPlayerPreview: NetworkMoviePreview?
    private var mediaPlayerItemID: ObjectIdentifier?
    private var mediaPlayerItemStatusObservation: NSKeyValueObservation?
    private var mediaPlayerFailedToEndObserver: NSObjectProtocol?
    private var failedMediaPlayerPreview: NetworkMoviePreview?
    private var failedMediaPlayerMessage: String?
    private var observesMoviePreviewPlayback = true
    private var moviePreviewPlayerFactory: MoviePreviewPlayerFactory
    private var textPreviewCoordinator = NetworkTextPreviewCoordinator()
    private var mediaPreviewCoordinator = NetworkMediaPreviewCoordinator()
    private let previewRenderState = NetworkBodyPreviewRenderState()
    private var syntaxViewConstraints: [NSLayoutConstraint] = []
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var shouldResetImageZoomOnNextLayout = false
    private var imagePreviewLayoutState: ImagePreviewLayoutState?
#if DEBUG
    private var bodyObservationDelivery: PortableObservationTracking.Token?
    private var previewRenderObservationDelivery: PortableObservationTracking.Token?
#endif

    package init(
        scrollEdgeSink: (any NetworkBodyScrollEdgeSink)? = nil,
        moviePreviewPlayerFactory: @escaping MoviePreviewPlayerFactory = {
            AVPlayer()
        }
    ) {
        self.scrollEdgeSink = scrollEdgeSink
        self.moviePreviewPlayerFactory = moviePreviewPlayerFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        configurePreviewViews()
#if DEBUG
        startObservingPreviewRenderStateForTesting()
#endif
    }

    override package func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateImagePreviewLayoutIfNeeded()
    }

    isolated deinit {
        bodyObservation?.cancel()
        tearDownMoviePreviewObservation()
#if DEBUG
        previewRenderObservationDelivery?.cancel()
#endif
        mediaPreviewCoordinator.cancel()
        textPreviewCoordinator.cancel()
    }

    package func setSurface(_ nextSurface: NetworkBodySurface) {
        setSurface(nextSurface, discardsVisibleResources: nextSurface.isRenderable == false)
    }

    package func resumeRendering() {
        guard isRenderingActive == false else {
            if surface.isRenderable {
                renderCurrentSurface()
            }
            return
        }

        isRenderingActive = true
        startObserving(body: surface.body)
        if surface.isRenderable {
            renderCurrentSurface()
        }
    }

    package func suspendKeepingSurface() {
        guard isRenderingActive else {
            return
        }

        isRenderingActive = false
        bodyObservation?.cancel()
        bodyObservation = nil
#if DEBUG
        bodyObservationDelivery = nil
#endif
        textPreviewCoordinator.suspendPreparation()
        mediaPreviewCoordinator.suspendPreparation()
        pauseMediaPreviewPlayback()
    }

    private func setSurface(
        _ nextSurface: NetworkBodySurface,
        discardsVisibleResources: Bool
    ) {
        guard surface.isEquivalent(to: nextSurface) == false else {
            if isRenderingActive, nextSurface.isRenderable {
                renderCurrentSurface()
            }
            return
        }

        if surface.body !== nextSurface.body || surface.metadata != nextSurface.metadata {
            textPreviewCoordinator.cancel()
            mediaPreviewCoordinator.cancel()
            failedMediaPlayerPreview = nil
            failedMediaPlayerMessage = nil
        }

        surface = nextSurface
        startObserving(body: nextSurface.body)

        if isRenderingActive, nextSurface.isRenderable {
            renderCurrentSurface()
        } else if discardsVisibleResources {
            textPreviewCoordinator.cancel()
            mediaPreviewCoordinator.cancel()
            hideMediaPreview()
            scrollEdgeSink?.contentScrollView = nil
        }
    }

    private func configurePreviewViews() {
        view.addSubview(imageScrollView)

        let imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 0)
        let imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 0)
        self.imageWidthConstraint = imageWidthConstraint
        self.imageHeightConstraint = imageHeightConstraint

        NSLayoutConstraint.activate([
            imageScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            imageScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.bottomAnchor),
            imageWidthConstraint,
            imageHeightConstraint,
        ])
        configureScrollEdgeObservedBackground(for: imageScrollView)
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        configureScrollEdgeObservedBackground(for: imageScrollView, backgroundColor: backgroundColor)
        if let syntaxView = syntaxViewStorage {
            configureScrollEdgeObservedBackground(for: syntaxView, backgroundColor: backgroundColor)
        }
    }

    private func configureScrollEdgeObservedBackground(
        for scrollView: UIScrollView,
        backgroundColor: UIColor? = nil
    ) {
        let backgroundColor = backgroundColor ?? webInspectorBackgroundPolicy.backgroundColor
        webInspectorConfigureScrollEdgeObservedScrollView(
            scrollView,
            backgroundColor: backgroundColor,
            traitCollection: traitCollection
        )
    }

    private func startObserving(body: NetworkBody?) {
        bodyObservation?.cancel()
        bodyObservation = nil
#if DEBUG
        bodyObservationDelivery = nil
#endif
        guard isRenderingActive,
              let body else {
            return
        }
        let token = withPortableContinuousObservation { [weak self, weak body] _ in
            guard let self,
                  let body,
                  body === self.surface.body else {
                return
            }
            self.renderBody(body)
        }
        bodyObservation = token
#if DEBUG
        bodyObservationDelivery = token
#endif
    }

#if DEBUG
    private func startObservingPreviewRenderStateForTesting() {
        previewRenderObservationDelivery?.cancel()
        previewRenderObservationDelivery = withPortableContinuousObservation { [weak self] _ in
            guard let self else {
                return
            }
            _ = previewRenderState.revision
        }
    }
#endif

    private func renderCurrentSurface() {
        switch surface {
        case .none:
            return
        case .unavailableBodyPlaceholder:
            renderBody(nil)
        case .body(let body, _):
            renderBody(body)
        }
    }

    private func renderBody(_ body: NetworkBody?) {
        guard isRenderingActive else {
            return
        }
        let displayText: String
        let syntaxKind: NetworkBody.SyntaxKind
        guard let body else {
            textPreviewCoordinator.cancel()
            hideMediaPreview()
            applyBodyDisplay(
                text: String(localized: "network.body.unavailable", bundle: WebInspectorUILocalization.bundle),
                syntaxKind: .plainText
            )
            return
        }

        if renderMediaPreviewIfPossible(for: body) {
            textPreviewCoordinator.cancel()
            return
        }

        switch body.phase {
        case .available, .fetching:
            textPreviewCoordinator.cancel()
            hideMediaPreview()
            displayText = ""
            syntaxKind = body.textRepresentationSyntaxKind
        case .loaded:
            let textAction = textPreviewCoordinator.preparePreview(for: body) { [weak self] result in
                self?.applyTextPreviewResult(result)
            }
            switch textAction {
            case .unavailable:
                displayText = String(localized: "network.body.unavailable", bundle: WebInspectorUILocalization.bundle)
                syntaxKind = .plainText
            case .active(let text, let preparedSyntaxKind), .ready(let text, let preparedSyntaxKind):
                displayText = text
                syntaxKind = preparedSyntaxKind
            }
        case .failed(let error):
            textPreviewCoordinator.cancel()
            hideMediaPreview()
            let text = body.textRepresentation
                ?? String(localized: "network.body.unavailable", bundle: WebInspectorUILocalization.bundle)
            displayText = text + "\n\n" + localizedDescription(for: error)
            syntaxKind = body.textRepresentationSyntaxKind
        }

        applyBodyDisplay(text: displayText, syntaxKind: syntaxKind)
    }

    private func applyTextPreviewResult(_ result: NetworkTextPreviewResultAction) {
        guard isRenderingActive else {
            return
        }
        switch result {
        case .ignore:
            return
        case .show(let text, let syntaxKind):
            applyBodyDisplay(text: text, syntaxKind: syntaxKind)
        }
    }

    private func localizedDescription(for failure: NetworkBody.Failure) -> String {
        switch failure {
        case .loadingFailed(let errorText, _):
            if errorText.isEmpty == false {
                return errorText
            }
            return String(localized: "network.body.fetch.error.unavailable", bundle: WebInspectorUILocalization.bundle)
        case .command(let error):
            switch error {
            case .rejected(let failure):
                return localizedDescription(for: failure)
            case .connection(let error):
                return localizedDescription(for: error)
            case .featureUnavailable(_, let error):
                return localizedDescription(for: error)
            case .staleIdentifier,
                 .targetChanged,
                 .timedOut,
                 .containerClosed:
                return String(localized: "network.body.fetch.error.unavailable", bundle: WebInspectorUILocalization.bundle)
            }
        }
    }

    private func localizedDescription(
        for error: WebInspectorFeatureError
    ) -> String {
        switch error {
        case .bootstrap(let failure),
             .eventStream(let failure),
             .command(let failure),
             .recoveryBudgetExhausted(let failure):
            localizedDescription(for: failure)
        }
    }

    private func localizedDescription(
        for error: WebInspectorConnectionFailure
    ) -> String {
        switch error {
        case .native(let failure),
             .transportEnvelope(let failure),
             .targetControlPlane(let failure):
            localizedDescription(for: failure)
        case .requiredFeature(_, let error):
            localizedDescription(for: error)
        }
    }

    private func localizedDescription(
        for failure: WebInspectorFailureDescription
    ) -> String {
        guard failure.message.isEmpty == false else {
            return String(localized: "network.body.fetch.error.unavailable", bundle: WebInspectorUILocalization.bundle)
        }
        return failure.message
    }

    private func applyBodyDisplay(
        text: String,
        syntaxKind: NetworkBody.SyntaxKind
    ) {
        let language = syntaxKind.language
        if syntaxModel.theme != .default {
            syntaxModel.theme = .default
        }
        if syntaxModel.text != text || syntaxModel.language != language {
            syntaxModel.replaceContents(text: text, language: language)
        }
        showSyntaxPreview()
    }

    private func renderMediaPreviewIfPossible(for body: NetworkBody) -> Bool {
        let action = mediaPreviewCoordinator.preparePreview(for: body, metadata: surface.metadata) { [weak self] result in
            self?.applyMediaPreviewResult(result)
        }
        switch action {
        case .unavailable:
            hideMediaPreview()
            return false
        case .failed:
            hideMediaPreview()
            return false
        case .active:
            if let failedMediaPlayerPreview {
                displayMoviePreviewFailure(
                    failedMediaPlayerPreview,
                    message: failedMediaPlayerMessage
                )
            }
            return true
        case .remoteMovie(let preview):
            showMoviePreview(preview)
            return true
        case .cachedMovie(let preview):
            showMoviePreview(preview)
            return true
        case .loadingMovie(let bodyID):
            showMoviePreviewLoadingState(bodyID: bodyID)
            return true
        case .unavailableMovie(let bodyID):
            showMoviePreviewUnavailableState(
                bodyID: bodyID,
                message: moviePreviewUnavailableMessage(for: body)
            )
            return true
        case .startedLoading:
            showMediaPreviewLoadingState()
            return true
        }
    }

    private func applyMediaPreviewResult(
        _ result: NetworkMediaPreviewResultAction
    ) {
        guard isRenderingActive else {
            return
        }
        switch result {
        case .ignore:
            return
        case .fallback:
            renderCurrentSurface()
        case .showImage(let image):
            showImagePreview(image)
        case .showMovie(let preview):
            showMoviePreview(preview)
        }
    }

    private func showMediaPreviewLoadingState() {
        hideImagePreview()
        removeMediaPlayerViewController()
        if syntaxModel.text.isEmpty == false || syntaxModel.language != .plainText {
            syntaxModel.replaceContents(text: "", language: .plainText)
        }
        installSyntaxPreviewIfNeeded()
        syntaxView.isHidden = false
        scrollEdgeSink?.contentScrollView = syntaxView
        previewRenderState.showLoading()
    }

    private func showMoviePreviewLoadingState(bodyID: ObjectIdentifier) {
        _ = installMoviePreviewSurfaceIfNeeded(bodyID: bodyID)
        clearMoviePreviewSourceIfNeeded(bodyID: bodyID, resetsFailure: true)
        showMoviePreviewStatus(UIContentUnavailableConfiguration.loading())
        previewRenderState.showMovieLoading(bodyID: bodyID)
    }

    private func showMoviePreviewUnavailableState(
        bodyID: ObjectIdentifier,
        message: String?
    ) {
        _ = installMoviePreviewSurfaceIfNeeded(bodyID: bodyID)
        clearMoviePreviewSourceIfNeeded(bodyID: bodyID, resetsFailure: false)
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "exclamationmark.triangle")
        configuration.text = String(
            localized: "network.body.unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.secondaryText = message
        showMoviePreviewStatus(configuration)
        previewRenderState.showMovieUnavailable(bodyID: bodyID)
    }

    private func moviePreviewUnavailableMessage(for body: NetworkBody) -> String? {
        guard case .failed(let failure) = body.phase else {
            return nil
        }
        return localizedDescription(for: failure)
    }

    private func showSyntaxPreview() {
        mediaPreviewCoordinator.prepareSyntaxPreview()
        hideImagePreview()
        removeMediaPlayerViewController()
        installSyntaxPreviewIfNeeded()
        syntaxView.isHidden = false
        scrollEdgeSink?.contentScrollView = syntaxView
        previewRenderState.showSyntax()
    }

    private func showImagePreview(_ image: UIImage) {
        removeMediaPlayerViewController()
        removeSyntaxPreview()
        imageScrollView.isHidden = false
        configureScrollEdgeObservedBackground(for: imageScrollView)
        scrollEdgeSink?.contentScrollView = imageScrollView
        shouldResetImageZoomOnNextLayout = true
        imagePreviewLayoutState = nil
        imageView.image = image
        imageWidthConstraint?.constant = max(image.size.width, 1)
        imageHeightConstraint?.constant = max(image.size.height, 1)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        updateImagePreviewLayoutIfNeeded()
        previewRenderState.showImage(size: image.size)
    }

    private func showMoviePreview(_ preview: NetworkMoviePreview) {
        let player = installMoviePreviewSurfaceIfNeeded(bodyID: preview.bodyID)
        if failedMediaPlayerPreview == preview {
            displayMoviePreviewFailure(
                preview,
                message: failedMediaPlayerMessage
            )
            return
        }
        if mediaPlayerPreview == preview,
           mediaPlayerViewController != nil {
            return
        }

        failedMediaPlayerPreview = nil
        failedMediaPlayerMessage = nil
        let item = AVPlayerItem(url: preview.url)
        let itemID = ObjectIdentifier(item)
        mediaPlayerPreview = preview
        mediaPlayerItemID = itemID
        observeMoviePreviewItem(item, itemID: itemID, preview: preview)

        player.replaceCurrentItem(with: item)
        hideMoviePreviewStatus()
        previewRenderState.showMovie(preview.url)
    }

    private func installMoviePreviewSurfaceIfNeeded(
        bodyID: ObjectIdentifier
    ) -> AVPlayer {
        if mediaPlayerSurfaceBodyID == bodyID,
           let player = mediaPlayerViewController?.player {
            return player
        }

        removeMediaPlayerViewController()
        hideImagePreview()
        removeSyntaxPreview()
        scrollEdgeSink?.contentScrollView = nil

        let playerViewController = AVPlayerViewController()
        let player = moviePreviewPlayerFactory()
        playerViewController.player = player
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(playerViewController)
        view.addSubview(playerViewController.view)
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            playerViewController.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        playerViewController.didMove(toParent: self)
        mediaPlayerSurfaceBodyID = bodyID
        mediaPlayerViewController = playerViewController
        return player
    }

    private func clearMoviePreviewSourceIfNeeded(
        bodyID: ObjectIdentifier,
        resetsFailure: Bool
    ) {
        guard mediaPlayerSurfaceBodyID == bodyID,
              let player = mediaPlayerViewController?.player else {
            return
        }
        if resetsFailure {
            failedMediaPlayerPreview = nil
            failedMediaPlayerMessage = nil
        }
        guard mediaPlayerPreview != nil
                || player.currentItem != nil
                || mediaPlayerItemStatusObservation != nil
                || mediaPlayerFailedToEndObserver != nil else {
            return
        }
        tearDownMoviePreviewObservation()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mediaPlayerPreview = nil
    }

    private func showMoviePreviewStatus(_ configuration: UIContentUnavailableConfiguration) {
        guard let playerViewController = mediaPlayerViewController,
              let overlayView = playerViewController.contentOverlayView else {
            return
        }
        let statusView: UIContentUnavailableView
        if let mediaPlayerStatusView {
            statusView = mediaPlayerStatusView
            statusView.configuration = configuration
        } else {
            statusView = UIContentUnavailableView(configuration: configuration)
            statusView.translatesAutoresizingMaskIntoConstraints = false
            statusView.backgroundColor = .clear
            statusView.isOpaque = false
            statusView.isUserInteractionEnabled = false
            overlayView.addSubview(statusView)
            NSLayoutConstraint.activate([
                statusView.topAnchor.constraint(equalTo: overlayView.topAnchor),
                statusView.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor),
                statusView.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor),
                statusView.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor),
            ])
            mediaPlayerStatusView = statusView
        }
        statusView.isHidden = false
    }

    private func hideMoviePreviewStatus() {
        mediaPlayerStatusView?.isHidden = true
    }

    private func observeMoviePreviewItem(
        _ item: AVPlayerItem,
        itemID: ObjectIdentifier,
        preview: NetworkMoviePreview
    ) {
        tearDownMoviePreviewObservation()
        mediaPlayerItemID = itemID
        guard observesMoviePreviewPlayback else {
            return
        }

        mediaPlayerItemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            let status = MoviePreviewItemStatus(item: item)
            Task { @MainActor [weak self] in
                self?.handleMoviePreviewItemStatus(
                    status,
                    itemID: itemID,
                    preview: preview
                )
            }
        }
        mediaPlayerFailedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: nil
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)?
                .localizedDescription
            Task { @MainActor [weak self] in
                self?.handleMoviePreviewFailure(
                    itemID: itemID,
                    preview: preview,
                    message: message
                )
            }
        }
    }

    private func handleMoviePreviewItemStatus(
        _ status: MoviePreviewItemStatus,
        itemID: ObjectIdentifier,
        preview: NetworkMoviePreview
    ) {
        guard mediaPlayerItemID == itemID,
              mediaPlayerPreview == preview else {
            return
        }
        switch status {
        case .unknown, .readyToPlay:
            return
        case .failed(let message):
            handleMoviePreviewFailure(
                itemID: itemID,
                preview: preview,
                message: message
            )
        }
    }

    private func handleMoviePreviewFailure(
        itemID: ObjectIdentifier,
        preview: NetworkMoviePreview,
        message: String?
    ) {
        guard mediaPlayerItemID == itemID,
              mediaPlayerPreview == preview else {
            return
        }
        failedMediaPlayerPreview = preview
        failedMediaPlayerMessage = message
        guard isRenderingActive else { return }
        displayMoviePreviewFailure(preview, message: message)
    }

    private func displayMoviePreviewFailure(
        _ preview: NetworkMoviePreview,
        message: String?
    ) {
        guard isRenderingActive,
              failedMediaPlayerPreview == preview,
              mediaPlayerSurfaceBodyID == preview.bodyID else {
            return
        }
        let failureText = if let message, message.isEmpty == false {
            message
        } else {
            String(
                localized: "network.body.fetch.error.unavailable",
                bundle: WebInspectorUILocalization.bundle
            )
        }
        showMoviePreviewUnavailableState(
            bodyID: preview.bodyID,
            message: failureText
        )
    }

    private func tearDownMoviePreviewObservation() {
        mediaPlayerItemStatusObservation?.invalidate()
        mediaPlayerItemStatusObservation = nil
        if let mediaPlayerFailedToEndObserver {
            NotificationCenter.default.removeObserver(mediaPlayerFailedToEndObserver)
        }
        mediaPlayerFailedToEndObserver = nil
        mediaPlayerItemID = nil
    }

    private func hideMediaPreview() {
        mediaPreviewCoordinator.hideMediaPreview()
        hideImagePreview()
        removeMediaPlayerViewController()
        installSyntaxPreviewIfNeeded()
        syntaxView.isHidden = false
        previewRenderState.showSyntax()
    }

    private func installSyntaxPreviewIfNeeded() {
        let syntaxView = syntaxView
        guard syntaxView.superview == nil else {
            configureScrollEdgeObservedBackground(for: syntaxView)
            return
        }
        view.insertSubview(syntaxView, belowSubview: imageScrollView)
        if syntaxViewConstraints.isEmpty {
            syntaxViewConstraints = [
                syntaxView.topAnchor.constraint(equalTo: view.topAnchor),
                syntaxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                syntaxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                syntaxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(syntaxViewConstraints)
        configureScrollEdgeObservedBackground(for: syntaxView)
    }

    private func removeSyntaxPreview() {
        guard let syntaxView = syntaxViewStorage else {
            return
        }
        syntaxView.isHidden = true
        guard syntaxView.superview != nil else {
            return
        }
        NSLayoutConstraint.deactivate(syntaxViewConstraints)
        syntaxView.removeFromSuperview()
    }

    private func pauseMediaPreviewPlayback() {
        mediaPlayerViewController?.player?.pause()
    }

    private func hideImagePreview() {
        imageScrollView.isHidden = true
        imageView.image = nil
        imageWidthConstraint?.constant = 0
        imageHeightConstraint?.constant = 0
        shouldResetImageZoomOnNextLayout = false
        imagePreviewLayoutState = nil
        imageScrollView.contentInset = .zero
        imageScrollView.contentOffset = .zero
        imageScrollView.minimumZoomScale = 1
        imageScrollView.maximumZoomScale = 1
        imageScrollView.zoomScale = 1
    }

    private func updateImagePreviewLayoutIfNeeded() {
        let didUpdate = updateImagePreviewLayout(resetZoom: shouldResetImageZoomOnNextLayout)
        if didUpdate {
            shouldResetImageZoomOnNextLayout = false
        }
    }

    @discardableResult
    private func updateImagePreviewLayout(resetZoom: Bool) -> Bool {
        guard imageScrollView.isHidden == false,
              let image = imageView.image,
              image.size.width > 0,
              image.size.height > 0,
              imageScrollView.bounds.width > 0,
              imageScrollView.bounds.height > 0
        else {
            return false
        }

        imageScrollView.layoutIfNeeded()
        imageScrollView.contentInset = .zero
        let imageSize = image.size
        let visibleBoundsSize = imagePreviewVisibleBoundsSize()
        guard visibleBoundsSize.width > 0, visibleBoundsSize.height > 0 else {
            return false
        }
        let fitScale = min(
            visibleBoundsSize.width / imageSize.width,
            visibleBoundsSize.height / imageSize.height
        )
        let minimumZoomScale = min(1, fitScale)
        let maximumZoomScale = max(4, 1 / minimumZoomScale)
        let isKeepingAutoFit = imagePreviewLayoutState.map { state in
            state.imageSize == imageSize
                && state.visibleBoundsSize != visibleBoundsSize
                && abs(imageScrollView.zoomScale - state.minimumZoomScale) < Self.imageZoomScaleTolerance
        } ?? false
        let targetZoomScale = resetZoom || isKeepingAutoFit
            ? minimumZoomScale
            : min(max(imageScrollView.zoomScale, minimumZoomScale), maximumZoomScale)

        imageScrollView.maximumZoomScale = maximumZoomScale
        imageScrollView.minimumZoomScale = minimumZoomScale
        imageScrollView.zoomScale = targetZoomScale
        imagePreviewLayoutState = ImagePreviewLayoutState(
            imageSize: imageSize,
            visibleBoundsSize: visibleBoundsSize,
            minimumZoomScale: minimumZoomScale
        )
        previewRenderState.updateImageLayout(
            imageSize: imageSize,
            visibleBoundsSize: visibleBoundsSize,
            minimumZoomScale: minimumZoomScale,
            zoomScale: targetZoomScale
        )
        return true
    }

    private func imagePreviewVisibleBoundsSize() -> CGSize {
        let adjustedInset = imageScrollView.adjustedContentInset
        return CGSize(
            width: max(imageScrollView.bounds.width - adjustedInset.left - adjustedInset.right, 0),
            height: max(imageScrollView.bounds.height - adjustedInset.top - adjustedInset.bottom, 0)
        )
    }

    private func removeMediaPlayerViewController() {
        tearDownMoviePreviewObservation()
        mediaPlayerPreview = nil
        mediaPlayerSurfaceBodyID = nil
        mediaPlayerStatusView?.removeFromSuperview()
        mediaPlayerStatusView = nil
        guard let mediaPlayerViewController else {
            return
        }
        pauseMediaPreviewPlayback()
        mediaPlayerViewController.player?.replaceCurrentItem(with: nil)
        mediaPlayerViewController.willMove(toParent: nil)
        mediaPlayerViewController.view.removeFromSuperview()
        mediaPlayerViewController.removeFromParent()
        mediaPlayerViewController.player = nil
        self.mediaPlayerViewController = nil
    }
}

extension NetworkBodyViewController: UIScrollViewDelegate {
    nonisolated package func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        MainActor.assumeIsolated {
            scrollView === imageScrollView ? imageView : nil
        }
    }

    nonisolated package func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        MainActor.assumeIsolated {
            guard scrollView === imageScrollView else {
                return
            }
            updateImagePreviewLayoutIfNeeded()
        }
    }
}

private struct ImagePreviewLayoutState {
    var imageSize: CGSize
    var visibleBoundsSize: CGSize
    var minimumZoomScale: CGFloat
}

private enum MoviePreviewItemStatus: Sendable {
    case unknown
    case readyToPlay
    case failed(String?)

    init(item: AVPlayerItem) {
        switch item.status {
        case .unknown:
            self = .unknown
        case .readyToPlay:
            self = .readyToPlay
        case .failed:
            self = .failed(item.error?.localizedDescription)
        @unknown default:
            self = .failed(nil)
        }
    }
}

@MainActor
@Observable
private final class NetworkBodyPreviewRenderState {
    private(set) var revision: UInt64 = 0
    private(set) var surface: NetworkBodyPreviewSurface = .syntax
    private(set) var imageLayout: NetworkBodyImagePreviewLayout?

    func showSyntax() {
        updateSurface(.syntax, imageLayout: nil)
    }

    func showLoading() {
        updateSurface(.loading, imageLayout: nil)
    }

    func showMovieLoading(bodyID: ObjectIdentifier) {
        updateSurface(.movieLoading(bodyID: bodyID), imageLayout: nil)
    }

    func showMovieUnavailable(bodyID: ObjectIdentifier) {
        updateSurface(.movieUnavailable(bodyID: bodyID), imageLayout: nil)
    }

    func showImage(size: CGSize) {
        updateSurface(.image(size: size), imageLayout: imageLayout)
    }

    func showMovie(_ url: URL) {
        updateSurface(.movie(url), imageLayout: nil)
    }

    func updateImageLayout(
        imageSize: CGSize,
        visibleBoundsSize: CGSize,
        minimumZoomScale: CGFloat,
        zoomScale: CGFloat
    ) {
        let layout = NetworkBodyImagePreviewLayout(
            imageSize: imageSize,
            visibleBoundsSize: visibleBoundsSize,
            minimumZoomScale: minimumZoomScale,
            zoomScale: zoomScale
        )
        guard imageLayout != layout else {
            return
        }
        imageLayout = layout
        incrementRevision()
    }

    private func updateSurface(
        _ nextSurface: NetworkBodyPreviewSurface,
        imageLayout nextImageLayout: NetworkBodyImagePreviewLayout?
    ) {
        guard surface != nextSurface || imageLayout != nextImageLayout else {
            return
        }
        surface = nextSurface
        imageLayout = nextImageLayout
        incrementRevision()
    }

    private func incrementRevision() {
        revision &+= 1
    }
}

private enum NetworkBodyPreviewSurface: Equatable {
    case syntax
    case loading
    case image(size: CGSize)
    case movieLoading(bodyID: ObjectIdentifier)
    case movieUnavailable(bodyID: ObjectIdentifier)
    case movie(URL)
}

private struct NetworkBodyImagePreviewLayout: Equatable {
    var imageSize: CGSize
    var visibleBoundsSize: CGSize
    var minimumZoomScale: CGFloat
    var zoomScale: CGFloat
}

private extension NetworkBodyViewController {
    static let imageZoomScaleTolerance: CGFloat = 0.001
}

private extension NetworkBody.SyntaxKind {
    var language: SyntaxLanguage {
        switch self {
        case .plainText:
            .plainText
        case .json:
            .json
        case .html:
            .html
        case .xml:
            .xml
        case .css:
            .css
        case .javascript:
            .javascript
        }
    }
}

#if DEBUG
struct NetworkBodyImagePreviewRenderSnapshot: Equatable {
    var imageSize: CGSize
    var visibleBoundsSize: CGSize
    var minimumZoomScale: CGFloat
    var zoomScale: CGFloat
}

extension NetworkBodyViewController {
    var syntaxModelTextForTesting: String {
        syntaxModel.text
    }

    var syntaxViewForTesting: SyntaxEditorView {
        loadViewIfNeeded()
        return syntaxView
    }

    var imageScrollViewForTesting: UIScrollView {
        loadViewIfNeeded()
        return imageScrollView
    }

    var imageViewForTesting: UIImageView {
        loadViewIfNeeded()
        return imageView
    }

    var isImagePreviewVisibleForTesting: Bool {
        loadViewIfNeeded()
        return imageScrollView.isHidden == false && imageView.image != nil
    }

    var imagePreviewRenderSnapshotForTesting: NetworkBodyImagePreviewRenderSnapshot? {
        loadViewIfNeeded()
        guard case let .image(imageSize) = previewRenderState.surface,
              let imageLayout = previewRenderState.imageLayout,
              imageLayout.imageSize == imageSize else {
            return nil
        }
        return NetworkBodyImagePreviewRenderSnapshot(
            imageSize: imageLayout.imageSize,
            visibleBoundsSize: imageLayout.visibleBoundsSize,
            minimumZoomScale: imageLayout.minimumZoomScale,
            zoomScale: imageLayout.zoomScale
        )
    }

    var mediaPlayerURLForTesting: URL? {
        loadViewIfNeeded()
        guard mediaPlayerViewController != nil else {
            return nil
        }
        return mediaPlayerPreview?.url
    }

    var mediaPlayerViewControllerForTesting: AVPlayerViewController? {
        loadViewIfNeeded()
        return mediaPlayerViewController
    }

    var mediaPlayerViewControllerIdentityForTesting: ObjectIdentifier? {
        mediaPlayerViewControllerForTesting.map(ObjectIdentifier.init)
    }

    var mediaPlayerSurfaceBodyIDForTesting: ObjectIdentifier? {
        loadViewIfNeeded()
        return mediaPlayerSurfaceBodyID
    }

    var mediaPlayerStatusConfigurationForTesting: UIContentUnavailableConfiguration? {
        loadViewIfNeeded()
        return mediaPlayerStatusView?.configuration as? UIContentUnavailableConfiguration
    }

    var isMoviePreviewStatusVisibleForTesting: Bool {
        loadViewIfNeeded()
        return mediaPlayerStatusView?.isHidden == false
    }

    var isMoviePreviewStatusHostedInPlayerOverlayForTesting: Bool {
        loadViewIfNeeded()
        guard let mediaPlayerStatusView,
              let contentOverlayView = mediaPlayerViewController?.contentOverlayView else {
            return false
        }
        return mediaPlayerStatusView.superview === contentOverlayView
    }

    var mediaPlayerIdentityForTesting: ObjectIdentifier? {
        loadViewIfNeeded()
        guard let player = mediaPlayerViewController?.player else {
            return nil
        }
        return ObjectIdentifier(player)
    }

    func setMoviePreviewPlayerFactoryForTesting(
        _ factory: @escaping MoviePreviewPlayerFactory
    ) {
        moviePreviewPlayerFactory = factory
        observesMoviePreviewPlayback = false
    }

    var mediaPlayerItemForTesting: AVPlayerItem? {
        loadViewIfNeeded()
        return mediaPlayerViewController?.player?.currentItem
    }

    var hasMoviePreviewObservationForTesting: Bool {
        loadViewIfNeeded()
        return mediaPlayerItemStatusObservation != nil
            && mediaPlayerFailedToEndObserver != nil
    }

    var hasMoviePreviewFailureForTesting: Bool {
        loadViewIfNeeded()
        return failedMediaPlayerPreview != nil
    }

    func waitUntilMediaPreviewPreparationFinishedForTesting() async {
        await mediaPreviewCoordinator.waitUntilPreparationFinishedForTesting()
    }

    var hasActiveTextPreviewPreparationForTesting: Bool {
        textPreviewCoordinator.hasActivePreparationForTesting
    }

    var activeTextPreviewPreparationBodyIDForTesting: ObjectIdentifier? {
        textPreviewCoordinator.activePreparationBodyIDForTesting
    }

    func waitUntilTextPreviewPreparationFinishedForTesting() async {
        await textPreviewCoordinator.waitUntilPreparationFinishedForTesting()
    }

    var bodyObservationDeliveryForTesting: PortableObservationTracking.Token? {
        bodyObservationDelivery
    }

    var previewRenderObservationDeliveryForTesting: PortableObservationTracking.Token? {
        loadViewIfNeeded()
        return previewRenderObservationDelivery
    }
}
#endif
#endif
