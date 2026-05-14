import Foundation
import V2_WebInspectorCore

package enum V2_NetworkResourceFilter: String, CaseIterable, Hashable, Sendable, Identifiable {
    case all
    case document
    case stylesheet
    case image
    case font
    case script
    case xhrFetch
    case other

    package var id: String { rawValue }

    package static var pickerCases: [V2_NetworkResourceFilter] {
        [
            .document,
            .stylesheet,
            .image,
            .font,
            .script,
            .xhrFetch,
            .other,
        ]
    }

    package static func normalizedSelection(
        _ selection: Set<V2_NetworkResourceFilter>
    ) -> Set<V2_NetworkResourceFilter> {
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
        from activeFilters: Set<V2_NetworkResourceFilter>
    ) -> Set<V2_NetworkResourceFilter> {
        activeFilters.isEmpty ? [.all] : activeFilters
    }

    var localizedTitle: String {
        switch self {
        case .all:
            v2WILocalized("network.filter.all", default: "All")
        case .document:
            v2WILocalized("network.filter.document", default: "Document")
        case .stylesheet:
            v2WILocalized("network.filter.stylesheet", default: "Stylesheet")
        case .image:
            v2WILocalized("network.filter.image", default: "Image")
        case .font:
            v2WILocalized("network.filter.font", default: "Font")
        case .script:
            v2WILocalized("network.filter.script", default: "Script")
        case .xhrFetch:
            v2WILocalized("network.filter.xhr_fetch", default: "XHR/Fetch")
        case .other:
            v2WILocalized("network.filter.other", default: "Other")
        }
    }

    init(resourceType: NetworkResourceType) {
        switch resourceType {
        case .document:
            self = .document
        case .styleSheet:
            self = .stylesheet
        case .image:
            self = .image
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

        if normalizedMimeType == "text/css" || pathExtension == "css" {
            self = .stylesheet
        } else if normalizedMimeType.hasPrefix("image/") {
            self = .image
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
