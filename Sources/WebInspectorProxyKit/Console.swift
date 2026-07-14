import Foundation

/// A target-scoped handle for Web Inspector Console commands and events.
public struct Console: Sendable, WebInspectorEventDomainHandle {
    package static let eventDecoder = ConsoleWireCoding.eventDecoder
    package static let eventCapability = ConsoleWireCoding.capability

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    /// Runs an operation with an atomically registered Console event scope.
    public func withEvents<Output>(
        buffering: WebInspectorEventBufferingPolicy = .bounded(256),
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<Console.Event>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        try await _withEvents(
            buffering: buffering,
            isolation: isolation,
            operation
        )
    }

    /// Clears console messages in the inspected target.
    public func clearMessages() async throws {
        try await endpoint.dispatch(ConsoleWireCoding.clearMessages)
    }

    /// Sets the logging level for a WebKit logging channel.
    public func setLoggingChannelLevel(_ source: ChannelSource, level: ChannelLevel) async throws {
        try await endpoint.dispatch(ConsoleWireCoding.setLoggingChannelLevel(source, level))
    }

    /// A console message payload reported by WebKit.
    public struct Message: Sendable {
        /// The source that produced the message.
        public let source: Source

        /// The severity level of the message.
        public let level: Level

        /// The message kind, if WebKit reported one.
        public let type: Kind?

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

        /// Runtime parameters attached to the message.
        public let parameters: [Runtime.RemoteObject]

        /// The JavaScript stack trace associated with the message.
        public let stackTrace: StackTrace?

        /// The network request associated with the message.
        public let networkRequestID: Network.Request.ID?

        /// The protocol timestamp for the message.
        public let timestamp: Double?

        /// Creates a console message payload.
        public init(
            source: Source,
            level: Level,
            type: Kind? = nil,
            text: String,
            url: String? = nil,
            line: Int? = nil,
            column: Int? = nil,
            repeatCount: Int = 1,
            parameters: [Runtime.RemoteObject] = [],
            stackTrace: StackTrace? = nil,
            networkRequestID: Network.Request.ID? = nil,
            timestamp: Double? = nil
        ) {
            self.source = source
            self.level = level
            self.type = type
            self.text = text
            self.url = url
            self.line = line
            self.column = column
            self.repeatCount = repeatCount
            self.parameters = parameters
            self.stackTrace = stackTrace
            self.networkRequestID = networkRequestID
            self.timestamp = timestamp
        }
    }

    /// A JavaScript stack trace.
    public struct StackTrace: Sendable {
        /// Frames in call order.
        public let callFrames: [CallFrame]

        /// Creates a stack trace.
        public init(callFrames: [CallFrame] = []) {
            self.callFrames = callFrames
        }
    }

    /// One JavaScript call frame.
    public struct CallFrame: Sendable {
        /// The function name reported by WebKit.
        public let functionName: String

        /// The source URL for the frame.
        public let url: String

        /// The source line for the frame.
        public let line: Int

        /// The source column for the frame.
        public let column: Int

        /// Creates a call frame.
        public init(functionName: String, url: String, line: Int, column: Int) {
            self.functionName = functionName
            self.url = url
            self.line = line
            self.column = column
        }
    }

    /// WebKit's console message source value.
    public struct Source: RawRepresentable, Hashable, Sendable {
        /// The raw protocol source.
        public let rawValue: String

        /// Creates a message source from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// WebKit's console severity level value.
    public struct Level: RawRepresentable, Hashable, Sendable {
        /// The raw protocol level.
        public let rawValue: String

        /// Creates a level from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// WebKit's console message kind value.
    public struct Kind: RawRepresentable, Hashable, Sendable {
        /// The raw protocol kind.
        public let rawValue: String

        /// Creates a message kind from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// Reason WebKit cleared console messages.
    public struct ClearReason: RawRepresentable, Hashable, Sendable {
        /// The raw protocol clear reason.
        public let rawValue: String

        /// Creates a clear reason from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// WebKit logging channel source.
    public struct ChannelSource: RawRepresentable, Hashable, Sendable {
        /// The raw protocol channel source.
        public let rawValue: String

        /// Creates a channel source from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// WebKit logging channel level.
    public struct ChannelLevel: RawRepresentable, Hashable, Sendable {
        /// The raw protocol channel level.
        public let rawValue: String

        /// Creates a channel level from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// Events emitted by the Console domain.
    public enum Event: Sendable {
        /// A message was added.
        case messageAdded(Message)

        /// The repeat count for the latest message changed.
        case messageRepeatCountUpdated(count: Int, timestamp: Double?)

        /// Console messages were cleared.
        case messagesCleared(reason: ClearReason)

        /// An event that is not modeled by this package.
        case unknown(RawEvent)
    }

}
