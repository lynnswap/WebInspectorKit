import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for one console message.
@Observable
public final class ConsoleMessage: WebInspectorPersistentModel {
    /// Stable identity for a console message within a context.
    public struct ID: WebInspectorPersistentIdentifier {
        /// The persistent model identified by this value.
        public typealias Model = ConsoleMessage

        package let canonicalStorage: CanonicalConsoleMessageIDStorage

        package init(canonical storage: CanonicalConsoleMessageIDStorage) {
            canonicalStorage = storage
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

    package init(
        id: ID,
        record: CanonicalConsoleMessageRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id.canonicalStorage == record.id,
            "A canonical ConsoleMessage must use its record identity."
        )
        self.id = id
        source = record.source
        level = record.level
        kind = record.kind
        text = record.text
        url = record.url
        line = record.line
        column = record.column
        repeatCount = record.repeatCount
        parameters = Self.makeCanonicalParameters(record)
        stackTrace = record.stackTrace.map(Self.stackTrace)
        networkRequestID = Self.networkRequestID(record.networkRequestReference)
        timestamp = record.timestamp
        targetID = record.membership.semanticTargetID
        self.modelContext = modelContext
    }

    package func replace(
        with record: CanonicalConsoleMessageRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id.canonicalStorage == record.id,
            "A ConsoleMessage replacement must preserve canonical identity."
        )
        source = record.source
        level = record.level
        kind = record.kind
        text = record.text
        url = record.url
        line = record.line
        column = record.column
        repeatCount = record.repeatCount
        parameters = Self.makeCanonicalParameters(record)
        stackTrace = record.stackTrace.map(Self.stackTrace)
        networkRequestID = Self.networkRequestID(record.networkRequestReference)
        timestamp = record.timestamp
        self.modelContext = modelContext
    }

    package func apply(_ patch: CanonicalConsoleMessagePatch) {
        switch patch {
        case let .repeatCount(count, timestamp):
            updateRepeatCount(count, timestamp: timestamp)
        case let .networkRequestReference(reference):
            networkRequestID = Self.networkRequestID(reference)
        }
    }

    package func invalidate() {
        modelContext = nil
    }

    func updateRepeatCount(_ count: Int, timestamp: Double?) {
        repeatCount = count
        self.timestamp = timestamp
    }

    private static func makeCanonicalParameters(
        _ record: CanonicalConsoleMessageRecord
    ) -> [RuntimeObject] {
        makeCanonicalParameters(
            id: ID(canonical: record.id),
            seeds: record.parameters
        )
    }

    private static func makeCanonicalParameters(
        id: ID,
        seeds: [CanonicalConsoleParameterResourceSeed]
    ) -> [RuntimeObject] {
        seeds.enumerated().map { index, seed in
            RuntimeObject(
                id: RuntimeObject.ID(
                    consoleMessageID: id,
                    parameterIndex: index
                ),
                payload: seed.payload
            )
        }
    }

    private static func stackTrace(
        _ stackTrace: CanonicalConsoleStackTrace
    ) -> Console.StackTrace {
        Console.StackTrace(
            callFrames: stackTrace.callFrames.map { frame in
                Console.CallFrame(
                    functionName: frame.functionName,
                    url: frame.url,
                    line: frame.line,
                    column: frame.column
                )
            }
        )
    }

    private static func networkRequestID(
        _ reference: CanonicalConsoleNetworkRequestReference?
    ) -> NetworkRequest.ID? {
        guard case let .resolved(_, storage)? = reference else {
            return nil
        }
        return NetworkRequest.ID(canonical: storage)
    }
}
