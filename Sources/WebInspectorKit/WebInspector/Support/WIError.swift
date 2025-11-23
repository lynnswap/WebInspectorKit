import Foundation

enum WIError: LocalizedError {
    case serializationFailed
    case subtreeUnavailable
    case scriptUnavailable
    
    var errorDescription: String? {
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
