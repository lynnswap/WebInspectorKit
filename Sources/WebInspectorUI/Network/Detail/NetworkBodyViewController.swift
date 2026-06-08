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
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.isHidden = true
        imageView.accessibilityIdentifier = "WebInspector.Network.BodyImagePreview"
        return imageView
    }()
    private let observationScope = ObservationScope()
    private weak var body: NetworkBody?
    private var metadata: NetworkBodyPreviewMetadata?
    private var hasDisplayedBody = false
    private var mediaPlayerViewController: AVPlayerViewController?
    private var mediaTemporaryFileURL: URL?
#if DEBUG
    private var bodyObservationDelivery: ObservationDelivery?
#endif

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

    isolated deinit {
        observationScope.cancelAll()
        removeTemporaryMediaFile(at: mediaTemporaryFileURL)
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
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            syntaxView.topAnchor.constraint(equalTo: view.topAnchor),
            syntaxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            syntaxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            syntaxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

        switch body.fetchState {
        case .available, .fetching:
            hideMediaPreview()
            displayText = ""
            syntaxKind = body.textRepresentationSyntaxKind
        case .loaded:
            if renderMediaPreviewIfPossible(for: body) {
                return
            }
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
        let mimeType = normalizedMIMEType(metadata?.mimeType)
        guard isMediaMIMEType(mimeType) || isMediaURL(metadata?.url) else {
            return nil
        }

        if isHLSMIMEType(mimeType) || isHLSURL(metadata?.url),
           let remoteURL = playableRemoteMediaURL(metadata?.url) {
            return .movie(remoteURL)
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

        if isImageMIMEType(mimeType) || isImageURL(metadata?.url),
           let image = UIImage(data: data) {
            return .image(image)
        }

        if isPlayableMIMEType(mimeType) || isPlayableURL(metadata?.url) {
            guard let fileURL = writeMediaData(data, mimeType: mimeType, url: metadata?.url) else {
                return nil
            }
            return .movie(fileURL)
        }

        return nil
    }

    private func showSyntaxPreview() {
        imageView.isHidden = true
        imageView.image = nil
        removeMediaPlayerViewController()
        syntaxView.isHidden = false
    }

    private func showImagePreview(_ image: UIImage) {
        removeMediaPlayerViewController()
        removeTemporaryMediaFile(at: mediaTemporaryFileURL)
        mediaTemporaryFileURL = nil
        syntaxView.isHidden = true
        imageView.image = image
        imageView.isHidden = false
    }

    private func showMoviePreview(_ url: URL) {
        imageView.isHidden = true
        imageView.image = nil
        syntaxView.isHidden = true
        if mediaTemporaryFileURL != url {
            removeTemporaryMediaFile(at: mediaTemporaryFileURL)
            mediaTemporaryFileURL = url
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
                playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
                playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            playerViewController.didMove(toParent: self)
            mediaPlayerViewController = playerViewController
        }
        playerViewController.player = AVPlayer(url: url)
    }

    private func hideMediaPreview() {
        imageView.isHidden = true
        imageView.image = nil
        removeMediaPlayerViewController()
        removeTemporaryMediaFile(at: mediaTemporaryFileURL)
        mediaTemporaryFileURL = nil
        syntaxView.isHidden = false
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

    private func writeMediaData(
        _ data: Data,
        mimeType: String?,
        url: String?
    ) -> URL? {
        let fileExtension = mediaFileExtension(mimeType: mimeType, url: url)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            return nil
        }
    }
}

private enum NetworkBodyMediaPayload {
    case image(UIImage)
    case movie(URL)
}

private func normalizedMIMEType(_ mimeType: String?) -> String? {
    mimeType?
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
        .first
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

private func isMediaMIMEType(_ mimeType: String?) -> Bool {
    isImageMIMEType(mimeType) || isPlayableMIMEType(mimeType)
}

private func isImageMIMEType(_ mimeType: String?) -> Bool {
    guard let mimeType else {
        return false
    }
    return mimeType.hasPrefix("image/") && mimeType != "image/svg+xml"
}

private func isPlayableMIMEType(_ mimeType: String?) -> Bool {
    guard let mimeType else {
        return false
    }
    return mimeType.hasPrefix("video/") || mimeType.hasPrefix("audio/") || isHLSMIMEType(mimeType)
}

private func isHLSMIMEType(_ mimeType: String?) -> Bool {
    switch mimeType {
    case "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/mpegurl",
         "audio/mpegurl", "audio/x-mpegurl":
        true
    default:
        false
    }
}

private func isMediaURL(_ url: String?) -> Bool {
    isImageURL(url) || isPlayableURL(url)
}

private func isImageURL(_ url: String?) -> Bool {
    switch pathExtension(url) {
    case "apng", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp":
        return true
    default:
        return false
    }
}

private func isPlayableURL(_ url: String?) -> Bool {
    switch pathExtension(url) {
    case "aac", "aif", "aiff", "m4a", "m4v", "m3u8", "mov", "mp3", "mp4", "wav":
        return true
    default:
        return false
    }
}

private func isHLSURL(_ url: String?) -> Bool {
    pathExtension(url) == "m3u8"
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

private func pathExtension(_ url: String?) -> String? {
    guard let url else {
        return nil
    }
    return URL(string: url)?.pathExtension.lowercased()
}

private func mediaFileExtension(mimeType: String?, url: String?) -> String {
    if let pathExtension = pathExtension(url), pathExtension.isEmpty == false {
        return pathExtension
    }
    switch mimeType {
    case "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/mpegurl",
         "audio/mpegurl", "audio/x-mpegurl":
        return "m3u8"
    case "audio/aac":
        return "aac"
    case "audio/aiff":
        return "aiff"
    case "audio/mpeg":
        return "mp3"
    case "audio/mp4":
        return "m4a"
    case "audio/wav", "audio/x-wav":
        return "wav"
    case "video/quicktime":
        return "mov"
    case "video/x-m4v":
        return "m4v"
    default:
        return "mp4"
    }
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

    var mediaPlayerURLForTesting: URL? {
        loadViewIfNeeded()
        return (mediaPlayerViewController?.player?.currentItem?.asset as? AVURLAsset)?.url
    }

    var bodyObservationDeliveryForTesting: ObservationDelivery? {
        bodyObservationDelivery
    }
}
#endif
#endif
