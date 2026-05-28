import OSLog

package enum InspectorRuntimeLog {
    private static let logger = Logger(
        subsystem: "com.lynnswap.WebInspectorKit",
        category: "Runtime"
    )

    package static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    package static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}
