import Foundation

public enum WINetworkResourceFilter: String, CaseIterable, Hashable, Sendable, Identifiable {
    case all
    case document
    case stylesheet
    case image
    case font
    case script
    case xhrFetch
    case other

    public var id: String { rawValue }

    public static var pickerCases: [WINetworkResourceFilter] {
        [
            .all,
            .document,
            .stylesheet,
            .image,
            .font,
            .script,
            .xhrFetch,
            .other
        ]
    }

    public static func normalizedSelection(
        _ selection: Set<WINetworkResourceFilter>
    ) -> Set<WINetworkResourceFilter> {
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

    public static func displaySelection(
        from activeFilters: Set<WINetworkResourceFilter>
    ) -> Set<WINetworkResourceFilter> {
        activeFilters.isEmpty ? [.all] : activeFilters
    }
}
