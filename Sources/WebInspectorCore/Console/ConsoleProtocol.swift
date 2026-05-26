package struct ConsoleMessageSource: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let xml = Self("xml")
    package static let javascript = Self("javascript")
    package static let network = Self("network")
    package static let consoleAPI = Self("console-api")
    package static let storage = Self("storage")
    package static let rendering = Self("rendering")
    package static let css = Self("css")
    package static let accessibility = Self("accessibility")
    package static let security = Self("security")
    package static let contentBlocker = Self("content-blocker")
    package static let media = Self("media")
    package static let mediaSource = Self("mediasource")
    package static let webRTC = Self("webrtc")
    package static let itpDebug = Self("itp-debug")
    package static let privateClickMeasurement = Self("private-click-measurement")
    package static let paymentRequest = Self("payment-request")
    package static let other = Self("other")
}

package struct ConsoleMessageLevel: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let log = Self("log")
    package static let info = Self("info")
    package static let warning = Self("warning")
    package static let error = Self("error")
    package static let debug = Self("debug")
}

package struct ConsoleMessageType: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let log = Self("log")
    package static let dir = Self("dir")
    package static let dirXML = Self("dirxml")
    package static let table = Self("table")
    package static let trace = Self("trace")
    package static let clear = Self("clear")
    package static let startGroup = Self("startGroup")
    package static let startGroupCollapsed = Self("startGroupCollapsed")
    package static let endGroup = Self("endGroup")
    package static let assert = Self("assert")
    package static let timing = Self("timing")
    package static let profile = Self("profile")
    package static let profileEnd = Self("profileEnd")
    package static let image = Self("image")
}

package struct ConsoleClearReason: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let consoleAPI = Self("console-api")
    package static let frontend = Self("frontend")
    package static let mainFrameNavigation = Self("main-frame-navigation")
}

package struct ConsoleLoggingChannelLevel: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let off = Self("off")
    package static let basic = Self("basic")
    package static let verbose = Self("verbose")
}

package struct ConsoleLoggingChannelPayload: Equatable, Sendable, Codable {
    package var source: ConsoleMessageSource
    package var level: ConsoleLoggingChannelLevel

    package init(source: ConsoleMessageSource, level: ConsoleLoggingChannelLevel) {
        self.source = source
        self.level = level
    }
}

package struct ConsoleMessagePayload: Equatable, Sendable, Codable {
    package var source: ConsoleMessageSource
    package var level: ConsoleMessageLevel
    package var text: String
    package var type: ConsoleMessageType?
    package var url: String?
    package var line: Int?
    package var column: Int?
    package var repeatCount: Int?
    package var parameters: [RuntimeRemoteObjectPayload]
    package var stackTrace: ConsoleStackTracePayload?
    package var networkRequestID: NetworkRequestIdentifier?
    package var timestamp: Double?

    package init(
        source: ConsoleMessageSource,
        level: ConsoleMessageLevel,
        text: String,
        type: ConsoleMessageType? = nil,
        url: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        repeatCount: Int? = nil,
        parameters: [RuntimeRemoteObjectPayload] = [],
        stackTrace: ConsoleStackTracePayload? = nil,
        networkRequestID: NetworkRequestIdentifier? = nil,
        timestamp: Double? = nil
    ) {
        self.source = source
        self.level = level
        self.text = text
        self.type = type
        self.url = url
        self.line = line
        self.column = column
        self.repeatCount = repeatCount
        self.parameters = parameters
        self.stackTrace = stackTrace
        self.networkRequestID = networkRequestID
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case level
        case text
        case type
        case url
        case line
        case column
        case repeatCount
        case parameters
        case stackTrace
        case networkRequestID = "networkRequestId"
        case timestamp
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(ConsoleMessageSource.self, forKey: .source)
        level = try container.decode(ConsoleMessageLevel.self, forKey: .level)
        text = try container.decode(String.self, forKey: .text)
        type = try container.decodeIfPresent(ConsoleMessageType.self, forKey: .type)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        column = try container.decodeIfPresent(Int.self, forKey: .column)
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount)
        parameters = try container.decodeIfPresent([RuntimeRemoteObjectPayload].self, forKey: .parameters) ?? []
        stackTrace = try container.decodeIfPresent(ConsoleStackTracePayload.self, forKey: .stackTrace)
        networkRequestID = try container.decodeIfPresent(NetworkRequestIdentifier.self, forKey: .networkRequestID)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
    }
}

package enum ConsoleCommandIntent: Equatable, Sendable {
    case enable(targetID: ProtocolTargetIdentifier)
    case disable(targetID: ProtocolTargetIdentifier)
    case clearMessages(targetID: ProtocolTargetIdentifier)
    case setConsoleClearAPIEnabled(targetID: ProtocolTargetIdentifier, enabled: Bool)
    case getLoggingChannels(targetID: ProtocolTargetIdentifier)
    case setLoggingChannelLevel(
        targetID: ProtocolTargetIdentifier,
        source: ConsoleMessageSource,
        level: ConsoleLoggingChannelLevel
    )

    package var targetID: ProtocolTargetIdentifier {
        switch self {
        case let .enable(targetID):
            targetID
        case let .disable(targetID):
            targetID
        case let .clearMessages(targetID):
            targetID
        case let .setConsoleClearAPIEnabled(targetID, _):
            targetID
        case let .getLoggingChannels(targetID):
            targetID
        case let .setLoggingChannelLevel(targetID, _, _):
            targetID
        }
    }
}
