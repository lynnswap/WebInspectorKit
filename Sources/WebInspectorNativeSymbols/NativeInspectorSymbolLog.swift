#if os(iOS) || os(macOS)
import OSLog

enum NativeInspectorSymbolLog {
    private static let logger = Logger(
        subsystem: "com.lynnswap.WebInspectorKit",
        category: "NativeSymbols"
    )

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}
#endif
