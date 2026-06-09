#if canImport(UIKit)
import AVKit
import WebInspectorCore
import ObservationBridge
import SyntaxEditorUI
import UIKit

struct NetworkBodyPreviewMetadata: Equatable {
    var mimeType: String?
    var url: String?
}

@MainActor
final class NetworkBodyViewController: UIViewController {
    private let syntaxModel = SyntaxEditorModel(
        text: "",
        language: .json,
        isEditable: false,
        lineWrappingEnabled: true,
        colorTheme: .v2WebInspectorPlainText,
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
    private let observationScope = ObservationScope()
    private let scrollEdgeState: NetworkDetailScrollEdgeState?
    private weak var body: NetworkBody?
    private var metadata: NetworkBodyPreviewMetadata?
    private var hasDisplayedBody = false
    private var mediaPlayerViewController: AVPlayerViewController?
    private var mediaTemporaryFile: MediaTemporaryFile?
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var shouldResetImageZoomOnNextLayout = false
    private var imagePreviewLayoutState: ImagePreviewLayoutState?
#if DEBUG
    private var bodyObservationDelivery: ObservationDelivery?
#endif

    init(scrollEdgeState: NetworkDetailScrollEdgeState? = nil) {
        self.scrollEdgeState = scrollEdgeState
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
        observationScope.cancelAll()
        removeTemporaryMediaFile(at: mediaTemporaryFile?.fileURL)
    }

    func display(body: NetworkBody?) {
        display(body: body, metadata: nil)
    }

    func display(body: NetworkBody?, metadata: NetworkBodyPreviewMetadata?) {
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
        scrollEdgeState?.contentScrollView = nil
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
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    private func startObserving(body: NetworkBody?) {
        observationScope.cancelAll()
#if DEBUG
        bodyObservationDelivery = nil
#endif
        guard let body else {
            return
        }
        let delivery = observationScope.observe(body) { [weak self] _, body in
            guard let self, body === self.body else {
                return
            }
            self.renderBody(body)
        }
#if DEBUG
        bodyObservationDelivery = delivery
#endif
    }

    private func renderBody(_ body: NetworkBody?) {
        let displayText: String
        let syntaxKind: NetworkBodySyntaxKind
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

        switch body.fetchState {
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

    private func localizedDescription(for error: NetworkBodyFetchError) -> String {
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
        syntaxKind: NetworkBodySyntaxKind
    ) {
        let syntax = syntaxKind.syntax
        if syntaxModel.language != syntax.language {
            syntaxModel.language = syntax.language
        }
        let colorTheme: SyntaxEditorColorTheme = syntax.usesPlainTextTheme ? .v2WebInspectorPlainText : .default
        if syntaxModel.colorTheme != colorTheme {
            syntaxModel.colorTheme = colorTheme
        }
        if syntaxModel.text != text {
            syntaxModel.replaceText(text)
        }
        showSyntaxPreview()
    }

    private func renderMediaPreviewIfPossible(for body: NetworkBody) -> Bool {
        guard let media = mediaPayload(for: body) else {
            hideMediaPreview()
            return false
        }

        switch media {
        case .image(let image):
            showImagePreview(image)
        case .movie(let url):
            showMoviePreview(url)
        }
        return true
    }

    private func mediaPayload(for body: NetworkBody) -> NetworkBodyMediaPayload? {
        guard let previewKind = NetworkMediaPreviewSupport.previewKind(
            mimeType: metadata?.mimeType,
            url: metadata?.url
        ) else {
            return nil
        }

        if previewKind == .hlsPlaylist {
            if body.role == .response, let remoteURL = playableRemoteMediaURL(metadata?.url) {
                return .movie(remoteURL)
            }
            if body.role == .request {
                return nil
            }
        }

        guard let rawBody = body.full else {
            return nil
        }
        let data: Data?
        if body.isBase64Encoded {
            data = Data(base64Encoded: rawBody)
        } else {
            data = rawBody.data(using: .utf8)
        }
        guard let data, data.isEmpty == false else {
            return nil
        }

        if previewKind == .image, let image = UIImage(data: data) {
            return .image(image)
        }

        if previewKind == .movie || previewKind == .hlsPlaylist {
            guard let fileURL = temporaryMediaFileURL(
                for: body,
                rawBody: rawBody,
                data: data,
                mimeType: metadata?.mimeType,
                url: metadata?.url
            ) else {
                return nil
            }
            return .movie(fileURL)
        }

        return nil
    }

    private func showSyntaxPreview() {
        hideImagePreview()
        removeMediaPlayerViewController()
        syntaxView.isHidden = false
        scrollEdgeState?.contentScrollView = syntaxView
    }

    private func showImagePreview(_ image: UIImage) {
        removeMediaPlayerViewController()
        removeCachedTemporaryMediaFile()
        syntaxView.isHidden = true
        imageScrollView.isHidden = false
        scrollEdgeState?.contentScrollView = imageScrollView
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
        scrollEdgeState?.contentScrollView = nil
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

    private func temporaryMediaFileURL(
        for body: NetworkBody,
        rawBody: String,
        data: Data,
        mimeType: String?,
        url: String?
    ) -> URL? {
        if let mediaTemporaryFile,
           mediaTemporaryFile.matches(
               body: body,
               rawBody: rawBody,
               isBase64Encoded: body.isBase64Encoded,
               mimeType: mimeType,
               url: url
           ),
           FileManager.default.fileExists(atPath: mediaTemporaryFile.fileURL.path) {
            return mediaTemporaryFile.fileURL
        }

        removeCachedTemporaryMediaFile()
        let fileExtension = mediaFileExtension(mimeType: mimeType, url: url)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: fileURL, options: [.atomic])
            mediaTemporaryFile = MediaTemporaryFile(
                bodyID: ObjectIdentifier(body),
                rawBody: rawBody,
                isBase64Encoded: body.isBase64Encoded,
                mimeType: mimeType,
                url: url,
                fileURL: fileURL
            )
            return fileURL
        } catch {
            return nil
        }
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

private enum NetworkBodyMediaPayload {
    case image(UIImage)
    case movie(URL)
}

private struct ImagePreviewLayoutState {
    var imageSize: CGSize
    var visibleBoundsSize: CGSize
    var minimumZoomScale: CGFloat
}

private struct MediaTemporaryFile {
    var bodyID: ObjectIdentifier
    var rawBody: String
    var isBase64Encoded: Bool
    var mimeType: String?
    var url: String?
    var fileURL: URL

    func matches(
        body: NetworkBody,
        rawBody: String,
        isBase64Encoded: Bool,
        mimeType: String?,
        url: String?
    ) -> Bool {
        bodyID == ObjectIdentifier(body)
            && self.rawBody == rawBody
            && self.isBase64Encoded == isBase64Encoded
            && self.mimeType == mimeType
            && self.url == url
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
    NetworkMediaPreviewSupport.temporaryFileExtension(mimeType: mimeType, url: url)
}

private func removeTemporaryMediaFile(at url: URL?) {
    guard let url else {
        return
    }
    try? FileManager.default.removeItem(at: url)
}

@MainActor
extension SyntaxEditorColorTheme {
    static let v2WebInspectorPlainText = SyntaxEditorColorTheme(
        baseForeground: .label,
        bracketBackground: .clear,
        comment: .label,
        string: .label,
        keyword: .label,
        number: .label,
        function: .label,
        type: .label,
        constant: .label,
        variable: .label,
        punctuation: .label
    )
}

private extension NetworkBodySyntaxKind {
    var syntax: (language: SyntaxLanguage, usesPlainTextTheme: Bool) {
        switch self {
        case .plainText:
            (.plainText, true)
        case .json:
            (.json, false)
        case .html:
            (.html, false)
        case .xml:
            (.xml, false)
        case .css:
            (.css, false)
        case .javascript:
            (.javascript, false)
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

    var bodyObservationDeliveryForTesting: ObservationDelivery? {
        bodyObservationDelivery
    }
}
#endif
#endif
