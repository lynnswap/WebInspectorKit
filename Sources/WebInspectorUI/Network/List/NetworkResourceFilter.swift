import WebInspectorCore
import Foundation

extension NetworkRequest.Display {
    package enum ResourceFilter: String, CaseIterable, Hashable, Sendable, Identifiable {        case all
        case document
        case stylesheet
        case media
        case font
        case script
        case xhrFetch
        case other

        package var id: String { rawValue }

        package static var pickerCases: [NetworkRequest.Display.ResourceFilter] {
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
            _ selection: Set<NetworkRequest.Display.ResourceFilter>
        ) -> Set<NetworkRequest.Display.ResourceFilter> {
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
            from activeFilters: Set<NetworkRequest.Display.ResourceFilter>
        ) -> Set<NetworkRequest.Display.ResourceFilter> {
            activeFilters.isEmpty ? [.all] : activeFilters
        }

        var localizedTitle: String {
            switch self {
            case .all:
                String(localized: "network.filter.all", bundle: .module)
            case .document:
                String(localized: "network.filter.document", bundle: .module)
            case .stylesheet:
                "CSS"
            case .media:
                String(localized: "network.filter.media", bundle: .module)
            case .font:
                String(localized: "network.filter.font", bundle: .module)
            case .script:
                "JS"
            case .xhrFetch:
                "XHR / Fetch"
            case .other:
                String(localized: "network.filter.other", bundle: .module)
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
            let normalizedMimeType = mimeType?
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first?
                .lowercased() ?? ""
            let pathExtension = URL(string: url)?.pathExtension.lowercased() ?? ""

            if case .previewable = NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url) {
                self = .media
            } else if normalizedMimeType == "text/css" || pathExtension == "css" {
                self = .stylesheet
            } else if normalizedMimeType.hasPrefix("font/") || ["woff", "woff2", "ttf", "otf"].contains(pathExtension) {
                self = .font
            } else if normalizedMimeType.contains("javascript") || ["js", "mjs"].contains(pathExtension) {
                self = .script
            } else if normalizedMimeType.contains("html") {
                self = .document
            } else {
                self = .other
            }
        }
    }
}
