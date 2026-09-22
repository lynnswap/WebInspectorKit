#if canImport(UIKit)
import WebInspectorDataKit

@MainActor
enum NetworkBodySurface {
    case none
    case emptyBodyPlaceholder
    case unavailableBodyPlaceholder
    case body(NetworkBody, metadata: NetworkMediaPreviewMetadata?)

    var body: NetworkBody? {
        if case .body(let body, _) = self {
            return body
        }
        return nil
    }

    var metadata: NetworkMediaPreviewMetadata? {
        if case .body(_, let metadata) = self {
            return metadata
        }
        return nil
    }

    var isRenderable: Bool {
        switch self {
        case .none:
            false
        case .emptyBodyPlaceholder, .unavailableBodyPlaceholder, .body:
            true
        }
    }

    func isEquivalent(to other: NetworkBodySurface) -> Bool {
        switch (self, other) {
        case (.none, .none),
             (.emptyBodyPlaceholder, .emptyBodyPlaceholder),
             (.unavailableBodyPlaceholder, .unavailableBodyPlaceholder):
            return true
        case (.body(let body, let metadata), .body(let otherBody, let otherMetadata)):
            return body === otherBody && metadata == otherMetadata
        default:
            return false
        }
    }
}

#endif
