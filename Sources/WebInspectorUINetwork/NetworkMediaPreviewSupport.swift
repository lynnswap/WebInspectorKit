import WebInspectorUIBase
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension NetworkDisplay {
    package enum MediaPreviewKind: Equatable, Sendable {
        case image
        case movie
        case hlsPlaylist
    }
}

extension NetworkDisplay {
    package enum MediaPreviewClassification: Equatable, Sendable {
        case previewable(NetworkDisplay.MediaPreviewKind)
        case notPreviewable
        case unknown
    }
}

extension NetworkDisplay {
    package enum MediaPreviewSupport {
        package static func previewKind(mimeType: String?, url: String?) -> NetworkDisplay.MediaPreviewKind? {
            guard case .previewable(let kind) = classification(mimeType: mimeType, url: url) else {
                return nil
            }
            return kind
        }

        package static func classification(
            mimeType: String?,
            url: String?
        ) -> NetworkDisplay.MediaPreviewClassification {
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
                if normalizedMIMEType.hasPrefix("audio/")
                    || normalizedMIMEType.hasPrefix("video/") {
                    return .notPreviewable
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
            }

            guard shouldInferFromURL(mimeType: normalizedMIMEType) else {
                return .unknown
            }

            if let classification = fastURLClassification(url) {
                return classification
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

        private static func classification(for type: UTType) -> NetworkDisplay.MediaPreviewClassification {
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
            supportedAudiovisualMIMETypes.contains(mimeType)
                || knownPlayableMIMETypes.contains(mimeType)
                || AVURLAsset.isPlayableExtendedMIMEType(mimeType)
        }

        private static func isSupportedImageMIMEType(_ mimeType: String) -> Bool {
            knownImageMIMETypes.contains(mimeType)
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
            pathExtension(url).map(knownImagePathExtensions.contains) == true
        }

        private static func fastURLClassification(_ url: String?) -> NetworkDisplay.MediaPreviewClassification? {
            guard let pathExtension = pathExtension(url), pathExtension.isEmpty == false else {
                return nil
            }
            if pathExtension == "m3u8" {
                return .previewable(.hlsPlaylist)
            }
            if pathExtension == "svg" {
                return .notPreviewable
            }
            if knownImagePathExtensions.contains(pathExtension) {
                return .previewable(.image)
            }
            if knownPlayablePathExtensions.contains(pathExtension) {
                return .previewable(.movie)
            }
            return nil
        }

        private static func imageClassification(url: String?) -> NetworkDisplay.MediaPreviewClassification {
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
            return NetworkDisplay.URLSummary(url: url).pathExtension
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

        private static let knownImageMIMETypes: Set<String> = [
            "image/apng",
            "image/avif",
            "image/bmp",
            "image/gif",
            "image/heic",
            "image/heif",
            "image/jpeg",
            "image/jpg",
            "image/pjpeg",
            "image/png",
            "image/tiff",
            "image/webp",
            "image/x-png",
        ]

        private static let knownPlayableMIMETypes: Set<String> = [
            "audio/aac",
            "audio/aiff",
            "audio/mp3",
            "audio/mp4",
            "audio/mpeg",
            "audio/wav",
            "audio/x-aiff",
            "audio/x-m4a",
            "audio/x-wav",
            "video/mp4",
            "video/quicktime",
            "video/x-m4v",
        ]

        private static let knownImagePathExtensions: Set<String> = [
            "apng",
            "avif",
            "bmp",
            "gif",
            "heic",
            "heif",
            "jpg",
            "jpeg",
            "png",
            "tif",
            "tiff",
            "webp",
        ]

        private static let knownPlayablePathExtensions: Set<String> = [
            "aac",
            "aif",
            "aiff",
            "caf",
            "m4a",
            "m4v",
            "mov",
            "mp3",
            "mp4",
            "wav",
        ]

        private static let supportedAudiovisualContentTypes = AVURLAsset.audiovisualTypes().compactMap { fileType in
            UTType(fileType.rawValue)
        }

        private static let supportedAudiovisualMIMETypes = Set(
            AVURLAsset.audiovisualMIMETypes().map { $0.lowercased() }
        )
    }
}
