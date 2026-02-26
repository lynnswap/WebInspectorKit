import Foundation

public enum WebInspectorCoreError: LocalizedError, Sendable {
    case serializationFailed
    case subtreeUnavailable
    case scriptUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .serializationFailed:
            return "Failed to serialize DOM tree."
        case .subtreeUnavailable:
            return "Failed to load child nodes."
        case .scriptUnavailable:
            return "Failed to load web inspector script."
        }
    }
}
