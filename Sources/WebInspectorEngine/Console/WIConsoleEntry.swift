import Foundation
import Observation

public enum WIConsoleEntryKind: String, Sendable {
    case message
    case command
    case result
}

public enum WIConsoleMessageSource: String, Decodable, Sendable {
    case xml
    case javascript
    case network
    case consoleAPI = "console-api"
    case storage
    case appcache
    case rendering
    case css
    case security
    case contentBlocker = "content-blocker"
    case media
    case mediaSource = "mediasource"
    case webRTC = "webrtc"
    case itpDebug = "itp-debug"
    case privateClickMeasurement = "private-click-measurement"
    case paymentRequest = "payment-request"
    case other

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .other
    }
}

public enum WIConsoleMessageLevel: String, Decodable, Sendable {
    case log
    case info
    case warning
    case error
    case debug

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .log
    }
}

public enum WIConsoleMessageType: String, Decodable, Sendable {
    case log
    case dir
    case dirxml
    case table
    case trace
    case clear
    case startGroup
    case startGroupCollapsed
    case endGroup
    case assert
    case timing
    case profile
    case profileEnd
    case image
    case command
    case result

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .log
    }
}

@MainActor
@Observable
public final class WIConsoleEntry: Identifiable, Equatable, Hashable {
    public struct Location: Hashable, Sendable {
        public let url: String
        public let line: Int?
        public let column: Int?

        public init(url: String, line: Int? = nil, column: Int? = nil) {
            self.url = url
            self.line = line
            self.column = column
        }
    }

    public struct StackFrame: Hashable, Sendable {
        public let functionName: String
        public let url: String
        public let line: Int?
        public let column: Int?

        public init(
            functionName: String,
            url: String,
            line: Int? = nil,
            column: Int? = nil
        ) {
            self.functionName = functionName
            self.url = url
            self.line = line
            self.column = column
        }
    }

    public static nonisolated func == (lhs: WIConsoleEntry, rhs: WIConsoleEntry) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public let id: UUID
    public let kind: WIConsoleEntryKind
    public let source: WIConsoleMessageSource
    public let level: WIConsoleMessageLevel
    public let type: WIConsoleMessageType
    public let text: String
    public let renderedText: String
    public let savedResultIndex: Int?
    public let wasThrown: Bool
    public let nestingLevel: Int
    public let networkRequestID: String?
    public private(set) var timestamp: Date
    public private(set) var repeatCount: Int
    public let location: Location?
    public let stackFrames: [StackFrame]

    public init(
        id: UUID = UUID(),
        kind: WIConsoleEntryKind,
        source: WIConsoleMessageSource,
        level: WIConsoleMessageLevel,
        type: WIConsoleMessageType,
        text: String,
        renderedText: String,
        timestamp: Date = .now,
        repeatCount: Int = 1,
        savedResultIndex: Int? = nil,
        wasThrown: Bool = false,
        nestingLevel: Int = 0,
        networkRequestID: String? = nil,
        location: Location? = nil,
        stackFrames: [StackFrame] = []
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.level = level
        self.type = type
        self.text = text
        self.renderedText = renderedText
        self.timestamp = timestamp
        self.repeatCount = max(1, repeatCount)
        self.savedResultIndex = savedResultIndex
        self.wasThrown = wasThrown
        self.nestingLevel = max(0, nestingLevel)
        self.networkRequestID = networkRequestID
        self.location = location
        self.stackFrames = stackFrames
    }

    package func updateRepeatCount(_ count: Int, timestamp: Date?) {
        repeatCount = max(1, count)
        if let timestamp {
            self.timestamp = timestamp
        }
    }
}
