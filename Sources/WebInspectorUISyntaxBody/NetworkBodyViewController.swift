#if canImport(UIKit)
import AVKit
import WebInspectorCore
import WebInspectorUIBase
import WebInspectorUINetwork
import Observation
import ObservationBridge
import SyntaxEditorUI
import UIKit

extension NetworkBodyViewController {
    typealias PreviewMetadata = NetworkMediaPreviewMetadata
}

@MainActor
package final class NetworkBodyViewController: UIViewController, NetworkBodyPreviewControlling {
    package typealias MoviePreviewPlayerFactory = @MainActor (URL) -> AVPlayer

    private let syntaxModel = SyntaxEditorModel(
        text: "",
        language: .json,
        isEditable: false,
        lineWrappingEnabled: true,
        theme: .default,
        drawsBackground: false
    )
    private lazy var syntaxView = SyntaxEditorView(
        model: syntaxModel
    )
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
    private var mediaPlayerURL: URL?
    private var moviePreviewPlayerFactory: MoviePreviewPlayerFactory
    private var textPreviewCoordinator = NetworkTextPreviewCoordinator()
    private var mediaPreviewCoordinator = NetworkMediaPreviewCoordinator()
    private let previewRenderState = NetworkBodyPreviewRenderState()
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
        moviePreviewPlayerFactory: @escaping MoviePreviewPlayerFactory = { url in
            AVPlayer(url: url)
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
        configureSyntaxView()
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

    private func configureSyntaxView() {
        syntaxView.translatesAutoresizingMaskIntoConstraints = false
        syntaxView.isEditable = false
        syntaxView.isSelectable = true
        syntaxView.isScrollEnabled = true
        syntaxView.alwaysBounceVertical = true
        syntaxView.contentInsetAdjustmentBehavior = .automatic
        syntaxView.keyboardDismissMode = .onDrag
        syntaxView.accessibilityIdentifier = "WebInspector.Network.BodyView"
        applyScrollEdgeObservedBackgrounds()
        view.addSubview(syntaxView)
        view.addSubview(imageScrollView)

        let imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 0)
        let imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 0)
        self.imageWidthConstraint = imageWidthConstraint
        self.imageHeightConstraint = imageHeightConstraint

        NSLayoutConstraint.activate([
            syntaxView.topAnchor.constraint(equalTo: view.topAnchor),
            syntaxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            syntaxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            syntaxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        applyScrollEdgeObservedBackgrounds(backgroundColor: backgroundColor)
    }

    private func applyScrollEdgeObservedBackgrounds(
        backgroundColor: UIColor? = nil
    ) {
        let backgroundColor = backgroundColor ?? webInspectorBackgroundPolicy.backgroundColor
        webInspectorConfigureScrollEdgeObservedScrollView(
            syntaxView,
            backgroundColor: backgroundColor,
            traitCollection: traitCollection
        )
        webInspectorConfigureScrollEdgeObservedScrollView(
            imageScrollView,
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

    private func localizedDescription(for error: NetworkBody.FetchError) -> String {
        switch error {
        case .unavailable:
            String(localized: "network.body.fetch.error.unavailable", bundle: WebInspectorUILocalization.bundle)
        case .decodeFailed:
            String(localized: "network.body.fetch.error.decode_failed", bundle: WebInspectorUILocalization.bundle)
        case .unknown(let message):
            message ?? String(localized: "network.body.fetch.error.unknown", bundle: WebInspectorUILocalization.bundle)
        }
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
            return true
        case .remoteMovie(let url):
            showMoviePreview(url)
            return true
        case .cachedMovie(let fileURL):
            showMoviePreview(fileURL)
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
        case .showMovie(let fileURL):
            showMoviePreview(fileURL)
        }
    }

    private func showMediaPreviewLoadingState() {
        hideImagePreview()
        removeMediaPlayerViewController()
        if syntaxModel.text.isEmpty == false || syntaxModel.language != .plainText {
            syntaxModel.replaceContents(text: "", language: .plainText)
        }
        syntaxView.isHidden = false
        applyScrollEdgeObservedBackgrounds()
        scrollEdgeSink?.contentScrollView = syntaxView
        previewRenderState.showLoading()
    }

    private func showSyntaxPreview() {
        mediaPreviewCoordinator.prepareSyntaxPreview()
        hideImagePreview()
        removeMediaPlayerViewController()
        syntaxView.isHidden = false
        applyScrollEdgeObservedBackgrounds()
        scrollEdgeSink?.contentScrollView = syntaxView
        previewRenderState.showSyntax()
    }

    private func showImagePreview(_ image: UIImage) {
        removeMediaPlayerViewController()
        syntaxView.isHidden = true
        imageScrollView.isHidden = false
        applyScrollEdgeObservedBackgrounds()
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

    private func showMoviePreview(_ url: URL) {
        hideImagePreview()
        syntaxView.isHidden = true
        scrollEdgeSink?.contentScrollView = nil

        let playerViewController: AVPlayerViewController
        if let current = mediaPlayerViewController {
            playerViewController = current
        } else {
            playerViewController = AVPlayerViewController()
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
            mediaPlayerViewController = playerViewController
        }
        if mediaPlayerURL == url {
            return
        }
        playerViewController.player = moviePreviewPlayerFactory(url)
        mediaPlayerURL = url
        previewRenderState.showMovie(url)
    }

    private func hideMediaPreview() {
        mediaPreviewCoordinator.hideMediaPreview()
        hideImagePreview()
        removeMediaPlayerViewController()
        syntaxView.isHidden = false
        previewRenderState.showSyntax()
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
        mediaPlayerURL = nil
        guard let mediaPlayerViewController else {
            return
        }
        pauseMediaPreviewPlayback()
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
        return mediaPlayerURL
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
