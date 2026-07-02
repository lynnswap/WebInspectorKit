import Foundation

public enum Console {
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func clearMessages() async throws {
            try await context.dispatchVoid(
                domain: .console,
                method: "clearMessages",
                payload: ClearMessagesPayload()
            )
        }

        public func setLoggingChannelLevel(_ source: ChannelSource, level: ChannelLevel) async throws {
            try await context.dispatchVoid(
                domain: .console,
                method: "setLoggingChannelLevel",
                payload: SetLoggingChannelLevelPayload(source: source, level: level)
            )
        }

        public var events: EventStream {
            EventStream {
                context.consoleEvents()
            }
        }
    }

    package struct ClearMessagesPayload: Sendable {
        package init() {}
    }

    package struct SetLoggingChannelLevelPayload: Sendable {
        package let source: ChannelSource
        package let level: ChannelLevel

        package init(source: ChannelSource, level: ChannelLevel) {
            self.source = source
            self.level = level
        }
    }

    public struct Message: Sendable {
        public let source: Source
        public let level: Level
        public let type: Kind?
        public let text: String
        public let url: String?
        public let line: Int?
        public let column: Int?
        public let repeatCount: Int
        public let parameters: [Runtime.RemoteObject]
        public let stackTrace: StackTrace?
        public let networkRequestID: Network.Request.ID?
        public let timestamp: Double?

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

    public struct StackTrace: Sendable {
        public let callFrames: [CallFrame]

        public init(callFrames: [CallFrame] = []) {
            self.callFrames = callFrames
        }
    }

    public struct CallFrame: Sendable {
        public let functionName: String
        public let url: String
        public let line: Int
        public let column: Int

        public init(functionName: String, url: String, line: Int, column: Int) {
            self.functionName = functionName
            self.url = url
            self.line = line
            self.column = column
        }
    }

    public struct Source: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct Level: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct Kind: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct ClearReason: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct ChannelSource: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct ChannelLevel: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public enum Event: Sendable {
        case messageAdded(Message)
        case messageRepeatCountUpdated(count: Int, timestamp: Double?)
        case messagesCleared(reason: ClearReason)
        case unknown(RawEvent)
    }

    public struct EventStream: AsyncSequence, Sendable {
        public typealias Element = Event
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            makeStream().makeAsyncIterator()
        }
    }
}
