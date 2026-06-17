#if canImport(UIKit)
import AVKit
import WebInspectorCore
import ObservationBridge
import SyntaxEditorUI
import UIKit

extension NetworkBodyViewController {
    struct PreviewMetadata: Equatable {        var mimeType: String?
        var url: String?
    }
}

@MainActor
final class NetworkBodyViewController: UIViewController {
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
    private weak var body: NetworkBody?
    private var metadata: NetworkBodyViewController.PreviewMetadata?
    private var hasDisplayedBody = false
    private var mediaPlayerViewController: AVPlayerViewController?
    private var mediaTemporaryFile: MediaTemporaryFile?
    private var mediaPreviewGeneration = 0
    private var mediaPreviewTask: Task<Void, Never>?
    private var pendingMediaPreviewInput: MediaPreviewInput?
    private var displayedMediaPreviewIdentity: MediaPreviewIdentity?
    private var failedMediaPreviewInput: MediaPreviewInput?
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var shouldResetImageZoomOnNextLayout = false
    private var imagePreviewLayoutState: ImagePreviewLayoutState?
#if DEBUG
    private var bodyObservationDelivery: PortableObservationTracking.Token?
#endif

    init(scrollEdgeSink: (any NetworkBodyScrollEdgeSink)? = nil) {
        self.scrollEdgeSink = scrollEdgeSink
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        configureSyntaxView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateImagePreviewLayoutIfNeeded()
    }

    isolated deinit {
        bodyObservation?.cancel()
        mediaPreviewTask?.cancel()
        removeTemporaryMediaFile(at: mediaTemporaryFile?.fileURL)
    }

    func display(body: NetworkBody?) {
        display(body: body, metadata: nil)
    }

    func display(body: NetworkBody?, metadata: NetworkBodyViewController.PreviewMetadata?) {
        guard hasDisplayedBody == false || self.body !== body else {
            guard self.metadata != metadata else {
                return
            }
            self.metadata = metadata
            renderBody(body)
            return
        }
        hasDisplayedBody = true
        self.body = body
        self.metadata = metadata
        startObserving(body: body)
        renderBody(body)
    }

    func releasePreviewResources() {
        hasDisplayedBody = false
        body = nil
        metadata = nil
        startObserving(body: nil)
        hideMediaPreview()
        scrollEdgeSink?.contentScrollView = nil
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
        guard let body else {
            return
        }
        let token = withPortableContinuousObservation { [weak self, weak body] _ in
            guard let self,
                  let body,
                  body === self.body else {
                return
            }
            self.renderBody(body)
        }
        bodyObservation = token
#if DEBUG
        bodyObservationDelivery = token
#endif
    }

    private func renderBody(_ body: NetworkBody?) {
        let displayText: String
        let syntaxKind: NetworkBody.SyntaxKind
        guard let body else {
            hideMediaPreview()
            applyBodyDisplay(
                text: String(localized: "network.body.unavailable", bundle: .module),
                syntaxKind: .plainText
            )
            return
        }

        if renderMediaPreviewIfPossible(for: body) {
            return
        }

        switch body.phase {
        case .available, .fetching:
            hideMediaPreview()
            displayText = ""
            syntaxKind = body.textRepresentationSyntaxKind
        case .loaded:
            body.prepareTextRepresentation()
            displayText = body.textRepresentation
                ?? String(localized: "network.body.unavailable", bundle: .module)
            syntaxKind = body.textRepresentationSyntaxKind
        case .failed(let error):
            hideMediaPreview()
            let text = body.textRepresentation
                ?? String(localized: "network.body.unavailable", bundle: .module)
            displayText = text + "\n\n" + localizedDescription(for: error)
            syntaxKind = body.textRepresentationSyntaxKind
        }

        applyBodyDisplay(text: displayText, syntaxKind: syntaxKind)
    }

    private func localizedDescription(for error: NetworkBody.FetchError) -> String {
        switch error {
        case .unavailable:
            String(localized: "network.body.fetch.error.unavailable", bundle: .module)
        case .decodeFailed:
            String(localized: "network.body.fetch.error.decode_failed", bundle: .module)
        case .unknown(let message):
            message ?? String(localized: "network.body.fetch.error.unknown", bundle: .module)
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
        guard let source = mediaPreviewSource(for: body) else {
            hideMediaPreview()
            return false
        }

        switch source {
        case .remoteMovie(let url):
            showRemoteMoviePreview(url)
            return true
        case .body(let input):
            return renderMediaPreview(for: input)
        }
    }

    private func mediaPreviewSource(for body: NetworkBody) -> MediaPreviewSource? {
        guard let previewKind = NetworkRequest.Display.MediaPreviewSupport.previewKind(
            mimeType: metadata?.mimeType,
            url: metadata?.url
        ) else {
            return nil
        }

        if previewKind == .hlsPlaylist {
            if body.role == .response, let remoteURL = playableRemoteMediaURL(metadata?.url) {
                return .remoteMovie(remoteURL)
            }
            if body.role == .request {
                return nil
            }
        }

        guard let rawBody = body.full else {
            return nil
        }
        return .body(
            MediaPreviewInput(
                previewKind: previewKind,
                bodyID: ObjectIdentifier(body),
                role: body.role,
                rawBody: rawBody,
                isBase64Encoded: body.isBase64Encoded,
                mimeType: metadata?.mimeType,
                url: metadata?.url
            )
        )
    }

    private func renderMediaPreview(for input: MediaPreviewInput) -> Bool {
        guard failedMediaPreviewInput != input else {
            hideMediaPreview()
            return false
        }

        if displayedMediaPreviewIdentity == .body(input) {
            return true
        }
        if pendingMediaPreviewInput == input {
            return true
        }
        if let fileURL = cachedTemporaryMediaFileURL(for: input) {
            cancelMediaPreviewTask()
            failedMediaPreviewInput = nil
            displayedMediaPreviewIdentity = .body(input)
            showMoviePreview(fileURL)
            return true
        }

        startMediaPreviewTask(for: input)
        return true
    }

    private func showRemoteMoviePreview(_ url: URL) {
        cancelMediaPreviewTask()
        failedMediaPreviewInput = nil
        displayedMediaPreviewIdentity = .remoteMovie(url)
        showMoviePreview(url)
    }

    private func startMediaPreviewTask(for input: MediaPreviewInput) {
        cancelMediaPreviewTask()
        failedMediaPreviewInput = nil
        pendingMediaPreviewInput = input
        mediaPreviewGeneration += 1
        let generation = mediaPreviewGeneration
        showMediaPreviewLoadingState(for: input)

        let worker = Task.detached(priority: .utility) {
            await NetworkBodyViewController.makeMediaPayload(from: input)
        }
        let task = Task { @MainActor [weak self, worker] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard Task.isCancelled == false else {
                result?.removeTemporaryFile()
                return
            }
            self?.applyMediaPreviewResult(result, input: input, generation: generation)
        }
        mediaPreviewTask = task
    }

    private func applyMediaPreviewResult(
        _ result: MediaPayload?,
        input: MediaPreviewInput,
        generation: Int
    ) {
        guard generation == mediaPreviewGeneration,
              pendingMediaPreviewInput == input else {
            result?.removeTemporaryFile()
            return
        }
        mediaPreviewTask = nil
        pendingMediaPreviewInput = nil

        guard let result else {
            failedMediaPreviewInput = input
            displayedMediaPreviewIdentity = nil
            renderBody(body)
            return
        }

        failedMediaPreviewInput = nil
        displayedMediaPreviewIdentity = .body(input)
        switch result {
        case .image(let image):
            showImagePreview(image)
        case .movie(let temporaryFile):
            replaceCachedTemporaryMediaFile(with: temporaryFile)
            showMoviePreview(temporaryFile.fileURL)
        }
    }

    private func showMediaPreviewLoadingState(for input: MediaPreviewInput) {
        displayedMediaPreviewIdentity = nil
        hideImagePreview()
        removeMediaPlayerViewController()
        if mediaTemporaryFile?.matches(input: input) != true {
            removeCachedTemporaryMediaFile()
        }
        if syntaxModel.text.isEmpty == false || syntaxModel.language != .plainText {
            syntaxModel.replaceContents(text: "", language: .plainText)
        }
        syntaxView.isHidden = false
        applyScrollEdgeObservedBackgrounds()
        scrollEdgeSink?.contentScrollView = syntaxView
    }

    private func cancelMediaPreviewTask() {
        mediaPreviewGeneration += 1
        mediaPreviewTask?.cancel()
        mediaPreviewTask = nil
        pendingMediaPreviewInput = nil
    }

    private func cachedTemporaryMediaFileURL(for input: MediaPreviewInput) -> URL? {
        guard input.previewKind == .movie || input.previewKind == .hlsPlaylist,
              let mediaTemporaryFile,
              mediaTemporaryFile.matches(input: input),
              FileManager.default.fileExists(atPath: mediaTemporaryFile.fileURL.path) else {
            return nil
        }
        return mediaTemporaryFile.fileURL
    }

    nonisolated private static func makeMediaPayload(from input: MediaPreviewInput) async -> MediaPayload? {
        guard let data = input.data(), data.isEmpty == false else {
            return nil
        }

        switch input.previewKind {
        case .image:
            var configuration = UIImageReader.Configuration()
            configuration.preparesImagesForDisplay = true
            let reader = UIImageReader(configuration: configuration)
            guard let image = await reader.image(data: data) else {
                return nil
            }
            return .image(image)
        case .movie, .hlsPlaylist:
            return makeTemporaryMediaPayload(from: input, data: data)
        }
    }

    nonisolated private static func makeTemporaryMediaPayload(
        from input: MediaPreviewInput,
        data: Data
    ) -> MediaPayload? {
        let fileExtension = mediaFileExtension(mimeType: input.mimeType, url: input.url)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: fileURL, options: [.atomic])
            return .movie(
                MediaTemporaryFile(
                    input: input,
                    fileURL: fileURL
                )
            )
        } catch {
            return nil
        }
    }

    private func showSyntaxPreview() {
        cancelMediaPreviewTask()
        displayedMediaPreviewIdentity = nil
        hideImagePreview()
        removeMediaPlayerViewController()
        syntaxView.isHidden = false
        applyScrollEdgeObservedBackgrounds()
        scrollEdgeSink?.contentScrollView = syntaxView
    }

    private func showImagePreview(_ image: UIImage) {
        removeMediaPlayerViewController()
        removeCachedTemporaryMediaFile()
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
    }

    private func showMoviePreview(_ url: URL) {
        hideImagePreview()
        syntaxView.isHidden = true
        scrollEdgeSink?.contentScrollView = nil
        if let temporaryFileURL = mediaTemporaryFile?.fileURL, temporaryFileURL != url {
            removeCachedTemporaryMediaFile()
        }

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
        if currentMediaURL(in: playerViewController) == url {
            return
        }
        playerViewController.player = AVPlayer(url: url)
    }

    private func hideMediaPreview() {
        cancelMediaPreviewTask()
        displayedMediaPreviewIdentity = nil
        hideImagePreview()
        removeMediaPlayerViewController()
        removeCachedTemporaryMediaFile()
        syntaxView.isHidden = false
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
        guard let mediaPlayerViewController else {
            return
        }
        mediaPlayerViewController.willMove(toParent: nil)
        mediaPlayerViewController.view.removeFromSuperview()
        mediaPlayerViewController.removeFromParent()
        mediaPlayerViewController.player = nil
        self.mediaPlayerViewController = nil
    }

    private func replaceCachedTemporaryMediaFile(with temporaryFile: MediaTemporaryFile) {
        if mediaTemporaryFile?.fileURL == temporaryFile.fileURL {
            mediaTemporaryFile = temporaryFile
            return
        }
        removeCachedTemporaryMediaFile()
        mediaTemporaryFile = temporaryFile
    }

    private func removeCachedTemporaryMediaFile() {
        removeTemporaryMediaFile(at: mediaTemporaryFile?.fileURL)
        mediaTemporaryFile = nil
    }

    private func currentMediaURL(in playerViewController: AVPlayerViewController) -> URL? {
        (playerViewController.player?.currentItem?.asset as? AVURLAsset)?.url
    }
}

extension NetworkBodyViewController: UIScrollViewDelegate {
    nonisolated func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        MainActor.assumeIsolated {
            scrollView === imageScrollView ? imageView : nil
        }
    }

    nonisolated func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        MainActor.assumeIsolated {
            guard scrollView === imageScrollView else {
                return
            }
            updateImagePreviewLayoutIfNeeded()
        }
    }
}

extension NetworkBodyViewController {
    fileprivate enum MediaPreviewSource {
        case remoteMovie(URL)
        case body(MediaPreviewInput)
    }

    fileprivate enum MediaPreviewIdentity: Equatable {
        case remoteMovie(URL)
        case body(MediaPreviewInput)
    }

    fileprivate struct MediaPreviewInput: Equatable, Sendable {
        var previewKind: NetworkRequest.Display.MediaPreviewKind
        var bodyID: ObjectIdentifier
        var role: NetworkBody.Role
        var rawBody: String
        var isBase64Encoded: Bool
        var mimeType: String?
        var url: String?

        func data() -> Data? {
            if isBase64Encoded {
                return Data(base64Encoded: rawBody)
            }
            return rawBody.data(using: .utf8)
        }
    }

    fileprivate enum MediaPayload {
        case image(UIImage)
        case movie(MediaTemporaryFile)

        func removeTemporaryFile() {
            if case .movie(let file) = self {
                removeTemporaryMediaFile(at: file.fileURL)
            }
        }
    }
}

private struct ImagePreviewLayoutState {
    var imageSize: CGSize
    var visibleBoundsSize: CGSize
    var minimumZoomScale: CGFloat
}

private struct MediaTemporaryFile {
    var input: NetworkBodyViewController.MediaPreviewInput
    var fileURL: URL

    func matches(input: NetworkBodyViewController.MediaPreviewInput) -> Bool {
        self.input == input
    }
}

private extension NetworkBodyViewController {
    static let imageZoomScaleTolerance: CGFloat = 0.001
}

private func playableRemoteMediaURL(_ url: String?) -> URL? {
    guard let url = url.flatMap(URL.init(string:)) else {
        return nil
    }
    switch url.scheme?.lowercased() {
    case "http", "https":
        return url
    default:
        return nil
    }
}

private func mediaFileExtension(mimeType: String?, url: String?) -> String {
    NetworkRequest.Display.MediaPreviewSupport.temporaryFileExtension(mimeType: mimeType, url: url)
}

private func removeTemporaryMediaFile(at url: URL?) {
    guard let url else {
        return
    }
    try? FileManager.default.removeItem(at: url)
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

    var mediaPlayerURLForTesting: URL? {
        loadViewIfNeeded()
        guard let mediaPlayerViewController else {
            return nil
        }
        return currentMediaURL(in: mediaPlayerViewController)
    }

    var mediaPlayerIdentityForTesting: ObjectIdentifier? {
        loadViewIfNeeded()
        guard let player = mediaPlayerViewController?.player else {
            return nil
        }
        return ObjectIdentifier(player)
    }

    var bodyObservationDeliveryForTesting: PortableObservationTracking.Token? {
        bodyObservationDelivery
    }
}
#endif
#endif
