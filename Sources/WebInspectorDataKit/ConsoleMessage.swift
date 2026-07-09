import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for one console message.
@Observable
public final class ConsoleMessage: WebInspectorFetchableModel {
    /// Stable identity for a console message within a context.
    public struct ID: Comparable, Hashable, Sendable {
        let ordinal: Int

        init(_ ordinal: Int) {
            self.ordinal = ordinal
        }

        /// Orders console messages by insertion ordinal.
        public static func < (lhs: ID, rhs: ID) -> Bool {
            lhs.ordinal < rhs.ordinal
        }
    }

    /// The stable message identity.
    public let id: ID

    /// The source that produced the message.
    public private(set) var source: Console.Source

    /// The severity level of the message.
    public private(set) var level: Console.Level

    /// The message kind, if WebKit reported one.
    public private(set) var kind: Console.Kind?

    /// The message text.
    public private(set) var text: String

    /// The source URL associated with the message.
    public private(set) var url: String?

    /// The source line associated with the message.
    public private(set) var line: Int?

    /// The source column associated with the message.
    public private(set) var column: Int?

    /// The number of repeated occurrences represented by the message.
    public private(set) var repeatCount: Int

    /// Runtime parameters attached to the message.
    public private(set) var parameters: [RuntimeObject]

    /// The JavaScript stack trace associated with the message.
    public private(set) var stackTrace: Console.StackTrace?

    /// The network request associated with the message.
    public private(set) var networkRequestID: NetworkRequest.ID?

    /// The protocol timestamp for the message.
    public private(set) var timestamp: Double?
    let targetID: WebInspectorTarget.ID?

    @ObservationIgnored weak var modelContext: WebInspectorContext?

    init(
        id: ID,
        message: Console.Message,
        parameters: [RuntimeObject],
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorContext
    ) {
        self.id = id
        source = message.source
        level = message.level
        kind = message.type
        text = message.text
        url = message.url
        line = message.line
        column = message.column
        repeatCount = message.repeatCount
        self.parameters = parameters
        stackTrace = message.stackTrace
        networkRequestID = message.networkRequestID.map(NetworkRequest.ID.init)
        timestamp = message.timestamp
        self.targetID = targetID
        self.modelContext = modelContext
    }

    func updateRepeatCount(_ count: Int, timestamp: Double?) {
        repeatCount = count
        self.timestamp = timestamp
    }
}
