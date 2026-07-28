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
}

extension WebInspectorContext.State {
    var logDescription: String {
        switch self {
        case .attaching:
            return "attaching"
        case .attached:
            return "attached"
        case .detached:
            return "detached"
        case let .failed(error):
            return "failed(\(String(describing: error)))"
        }
    }
}
