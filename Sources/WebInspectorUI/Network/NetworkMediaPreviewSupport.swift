import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

package enum NetworkMediaPreviewKind: Equatable, Sendable {
    case image
    case movie
    case hlsPlaylist
}

package enum NetworkMediaPreviewClassification: Equatable, Sendable {
    case previewable(NetworkMediaPreviewKind)
    case notPreviewable
    case unknown
}

package enum NetworkMediaPreviewSupport {
    package static func previewKind(mimeType: String?, url: String?) -> NetworkMediaPreviewKind? {
        guard case .previewable(let kind) = classification(mimeType: mimeType, url: url) else {
            return nil
        }
        return kind
    }

    package static func classification(
        mimeType: String?,
        url: String?
    ) -> NetworkMediaPreviewClassification {
        let normalizedMIMEType = normalizedMIMEType(mimeType)

        if isHLSMIMEType(normalizedMIMEType) {
            return .previewable(.hlsPlaylist)
        }

        if let normalizedMIMEType {
            if isSVGMIMEType(normalizedMIMEType) {
                return .notPreviewable
            }
            if isSupportedImageMIMEType(normalizedMIMEType) {
                return .previewable(.image)
            }
            if isPlayableMIMEType(normalizedMIMEType) {
                return .previewable(.movie)
            }
            if let type = contentType(mimeType: normalizedMIMEType) {
                let classification = classification(for: type)
                switch classification {
                case .previewable, .notPreviewable:
                    return classification
                case .unknown:
                    break
                }
            }
            if normalizedMIMEType.hasPrefix("image/") {
                if case .previewable(.image) = imageClassification(url: url) {
                    return .previewable(.image)
                }
                return .notPreviewable
            }
            if normalizedMIMEType.hasPrefix("audio/")
                || normalizedMIMEType.hasPrefix("video/") {
                return .notPreviewable
            }
        }

        guard shouldInferFromURL(mimeType: normalizedMIMEType) else {
            return .unknown
        }

        if isHLSURL(url) {
            return .previewable(.hlsPlaylist)
        }

        if isSupportedImageURL(url) {
            return .previewable(.image)
        }

        if let type = contentType(url: url) {
            let classification = classification(for: type)
            switch classification {
            case .previewable, .notPreviewable:
                return classification
            case .unknown:
                break
            }
        }

        return .unknown
    }

    package static func temporaryFileExtension(mimeType: String?, url: String?) -> String {
        let normalizedMIMEType = normalizedMIMEType(mimeType)

        if let normalizedMIMEType,
           case .previewable = classification(mimeType: normalizedMIMEType, url: nil) {
            return temporaryFileExtension(forNormalizedMIMEType: normalizedMIMEType) ?? "mp4"
        }

        if let pathExtension = pathExtension(url), pathExtension.isEmpty == false {
            return pathExtension
        }

        return temporaryFileExtension(forNormalizedMIMEType: normalizedMIMEType) ?? "mp4"
    }

    private static func temporaryFileExtension(forNormalizedMIMEType normalizedMIMEType: String?) -> String? {
        if isHLSMIMEType(normalizedMIMEType) {
            return "m3u8"
        }
        if let normalizedMIMEType,
           let preferredExtension = contentType(mimeType: normalizedMIMEType)?.preferredFilenameExtension {
            return preferredExtension
        }

        switch normalizedMIMEType {
        case "audio/aiff":
            return "aiff"
        case "audio/mp4":
            return "m4a"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "video/x-m4v":
            return "m4v"
        default:
            return nil
        }
    }

    private static func classification(for type: UTType) -> NetworkMediaPreviewClassification {
        if type.conforms(to: .svg) {
            return .notPreviewable
        }
        if type.conforms(to: .image) {
            return isSupportedImageType(type) ? .previewable(.image) : .notPreviewable
        }
        if isSupportedAudiovisualType(type) {
            return .previewable(.movie)
        }
        if type.conforms(to: .audio)
            || type.conforms(to: .movie)
            || type.conforms(to: .video)
            || type.conforms(to: .audiovisualContent) {
            return .notPreviewable
        }
        return .unknown
    }

    private static func contentType(mimeType: String) -> UTType? {
        UTType(mimeType: mimeType, conformingTo: .data)
    }

    private static func contentType(url: String?) -> UTType? {
        guard let pathExtension = pathExtension(url), pathExtension.isEmpty == false else {
            return nil
        }
        return UTType(filenameExtension: pathExtension, conformingTo: .data)
    }

    private static func isSupportedImageType(_ type: UTType) -> Bool {
        supportedImageTypes.contains { supportedType in
            type.conforms(to: supportedType)
        }
    }

    private static func isSupportedAudiovisualType(_ type: UTType) -> Bool {
        supportedAudiovisualContentTypes.contains { supportedType in
            type.conforms(to: supportedType)
        }
    }

    private static func isPlayableMIMEType(_ mimeType: String) -> Bool {
        supportedAudiovisualMIMETypes.contains(mimeType) || AVURLAsset.isPlayableExtendedMIMEType(mimeType)
    }

    private static func isSupportedImageMIMEType(_ mimeType: String) -> Bool {
        switch mimeType {
        case "image/apng", "image/pjpeg", "image/x-png":
            return true
        default:
            return false
        }
    }

    private static func isSVGMIMEType(_ mimeType: String) -> Bool {
        mimeType == "image/svg+xml"
    }

    private static func isHLSMIMEType(_ mimeType: String?) -> Bool {
        switch mimeType {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/mpegurl",
             "audio/mpegurl", "audio/x-mpegurl":
            true
        default:
            false
        }
    }

    private static func isHLSURL(_ url: String?) -> Bool {
        pathExtension(url) == "m3u8"
    }

    private static func isSupportedImageURL(_ url: String?) -> Bool {
        switch pathExtension(url) {
        case "apng":
            return true
        default:
            return false
        }
    }

    private static func imageClassification(url: String?) -> NetworkMediaPreviewClassification {
        if isSupportedImageURL(url) {
            return .previewable(.image)
        }
        if let type = contentType(url: url) {
            return classification(for: type)
        }
        return .unknown
    }

    private static func normalizedMIMEType(_ mimeType: String?) -> String? {
        mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    private static func pathExtension(_ url: String?) -> String? {
        guard let url else {
            return nil
        }
        return URL(string: url)?.pathExtension.lowercased()
    }

    private static func shouldInferFromURL(mimeType: String?) -> Bool {
        guard let mimeType else {
            return true
        }
        switch mimeType {
        case "application/octet-stream", "binary/octet-stream":
            return true
        default:
            return false
        }
    }

    private static let supportedImageTypes: [UTType] = {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap(UTType.init)
    }()

    private static let supportedAudiovisualContentTypes = AVURLAsset.audiovisualTypes().compactMap { fileType in
        UTType(fileType.rawValue)
    }

    private static let supportedAudiovisualMIMETypes = Set(
        AVURLAsset.audiovisualMIMETypes().map { $0.lowercased() }
    )
}
