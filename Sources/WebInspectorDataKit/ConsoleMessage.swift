import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for one console message.
@Observable
public final class ConsoleMessage: WebInspectorPersistentModel {
    /// Stable identity for a console message within a context.
    public struct ID: Comparable, WebInspectorPersistentIdentifier {
        /// The persistent model identified by this value.
        public typealias Model = ConsoleMessage

        let ordinal: Int

        init(_ ordinal: Int) {
            self.ordinal = ordinal
        }

        /// Orders console messages by insertion ordinal.
        public static func < (lhs: ID, rhs: ID) -> Bool {
            lhs.ordinal < rhs.ordinal
        }
    }

    /// Immutable Console fields available to typed fetch descriptors.
    public struct QueryValue: Identifiable, Sendable {
        /// The message identity.
        public let id: ID

        /// The message's stable insertion position in its source generation.
        public let insertionIndex: Int

        /// The source that produced the message.
        public let source: Console.Source

        /// The severity level of the message.
        public let level: Console.Level

        /// The message kind, if WebKit reported one.
        public let kind: Console.Kind?

        /// The message text.
        public let text: String

        /// The source URL associated with the message.
        public let url: String?

        /// The source line associated with the message.
        public let line: Int?

        /// The source column associated with the message.
        public let column: Int?

        /// The number of repeated occurrences represented by the message.
        public let repeatCount: Int

        /// The protocol timestamp for the message.
        public let timestamp: Double?

        package init(
            id: ID,
            insertionIndex: Int,
            source: Console.Source,
            level: Console.Level,
            kind: Console.Kind?,
            text: String,
            url: String?,
            line: Int?,
            column: Int?,
            repeatCount: Int,
            timestamp: Double?
        ) {
            self.id = id
            self.insertionIndex = insertionIndex
            self.source = source
            self.level = level
            self.kind = kind
            self.text = text
            self.url = url
            self.line = line
            self.column = column
            self.repeatCount = repeatCount
            self.timestamp = timestamp
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

    @ObservationIgnored weak var modelContext: WebInspectorModelContext?

    init(
        id: ID,
        message: Console.Message,
        parameters: [RuntimeObject],
        targetID: WebInspectorTarget.ID?,
        modelContext: WebInspectorModelContext
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
