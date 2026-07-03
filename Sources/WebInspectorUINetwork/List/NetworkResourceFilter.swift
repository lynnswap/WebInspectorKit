import WebInspectorUIBase
import WebInspectorCore
import Foundation

extension NetworkDisplay {
    package enum ResourceFilter: String, CaseIterable, Hashable, Sendable, Identifiable {
        case all
        case document
        case stylesheet
        case media
        case font
        case script
        case xhrFetch
        case other

        package var id: String { rawValue }

        package static var pickerCases: [NetworkDisplay.ResourceFilter] {
            [
                .document,
                .stylesheet,
                .media,
                .font,
                .script,
                .xhrFetch,
                .other,
            ]
        }

        package static func normalizedSelection(
            _ selection: Set<NetworkDisplay.ResourceFilter>
        ) -> Set<NetworkDisplay.ResourceFilter> {
            if selection.contains(.all) {
                if selection.count == 1 {
                    return []
                }
                var trimmed = selection
                trimmed.remove(.all)
                return trimmed
            }
            return selection
        }

        package static func displaySelection(
            from activeFilters: Set<NetworkDisplay.ResourceFilter>
        ) -> Set<NetworkDisplay.ResourceFilter> {
            activeFilters.isEmpty ? [.all] : activeFilters
        }

        var localizedTitle: String {
            switch self {
            case .all:
                String(localized: "network.filter.all", bundle: WebInspectorUILocalization.bundle)
            case .document:
                String(localized: "network.filter.document", bundle: WebInspectorUILocalization.bundle)
            case .stylesheet:
                "CSS"
            case .media:
                String(localized: "network.filter.media", bundle: WebInspectorUILocalization.bundle)
            case .font:
                String(localized: "network.filter.font", bundle: WebInspectorUILocalization.bundle)
            case .script:
                "JS"
            case .xhrFetch:
                "XHR / Fetch"
            case .other:
                String(localized: "network.filter.other", bundle: WebInspectorUILocalization.bundle)
            }
        }

        init(resourceType: NetworkRequest.ResourceType) {
            switch resourceType {
            case .document:
                self = .document
            case .styleSheet:
                self = .stylesheet
            case .image, .media:
                self = .media
            case .font:
                self = .font
            case .script:
                self = .script
            case .xhr, .fetch, .ping, .beacon:
                self = .xhrFetch
            default:
                self = .other
            }
        }

        init(mimeType: String?, url: String) {
            let urlSummary = NetworkDisplay.URLSummary(url: url)
            self = Self.inferred(
                mimeType: mimeType,
                pathExtension: urlSummary.pathExtension,
                mediaPreviewClassification: NetworkDisplay.MediaPreviewSupport.classification(
                    mimeType: mimeType,
                    url: url
                )
            )
        }

        package static func inferred(
            mimeType: String?,
            pathExtension: String?,
            mediaPreviewClassification: NetworkDisplay.MediaPreviewClassification
        ) -> NetworkDisplay.ResourceFilter {
            let normalizedMimeType = mimeType?
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first?
                .lowercased() ?? ""
            let pathExtension = pathExtension ?? ""

            if case .previewable = mediaPreviewClassification {
                return .media
            } else if normalizedMimeType == "text/css" || pathExtension == "css" {
                return .stylesheet
            } else if normalizedMimeType.hasPrefix("font/") || ["woff", "woff2", "ttf", "otf"].contains(pathExtension) {
                return .font
            } else if normalizedMimeType.contains("javascript") || ["js", "mjs"].contains(pathExtension) {
                return .script
            } else if normalizedMimeType.contains("html") {
                return .document
            } else {
                return .other
            }
        }
    }
}
