import Foundation
import OSLog

private let logger = Logger(
    subsystem: "com.lynnswap.WebInspectorKit",
    category: "WebInspectorDataKit"
)

enum WebInspectorDataKitLog {
    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

extension WebInspectorModelContext.State {
    var logDescription: String {
        switch self {
        case .attaching:
            return "attaching"
        case let .synchronizing(generation):
            return "synchronizing(\(generation))"
        case .attached:
            return "attached"
        case .detached:
            return "detached"
        case .detaching:
            return "detaching"
        case .closed:
            return "closed"
        case let .failed(error):
            return "failed(\(String(describing: error)))"
        }
    }
}
