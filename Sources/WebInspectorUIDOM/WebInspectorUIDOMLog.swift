import Foundation
import OSLog

private let logger = Logger(
    subsystem: "com.lynnswap.WebInspectorKit",
    category: "WebInspectorUIDOM"
)

enum WebInspectorUIDOMLog {
    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
