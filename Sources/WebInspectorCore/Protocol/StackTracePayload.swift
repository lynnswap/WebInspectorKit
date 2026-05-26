package struct ConsoleCallFramePayload: Equatable, Sendable, Codable {
    package var functionName: String
    package var url: String
    package var scriptID: String
    package var lineNumber: Int
    package var columnNumber: Int

    package init(functionName: String, url: String, scriptID: String, lineNumber: Int, columnNumber: Int) {
        self.functionName = functionName
        self.url = url
        self.scriptID = scriptID
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
    }

    private enum CodingKeys: String, CodingKey {
        case functionName
        case url
        case scriptID = "scriptId"
        case lineNumber
        case columnNumber
    }
}

package struct ConsoleStackTracePayload: Equatable, Sendable, Codable {
    package var callFrames: [ConsoleCallFramePayload]
    package var topCallFrameIsBoundary: Bool?
    package var truncated: Bool?
    package var parentStackTraces: [ConsoleStackTracePayload]

    package init(
        callFrames: [ConsoleCallFramePayload],
        topCallFrameIsBoundary: Bool? = nil,
        truncated: Bool? = nil,
        parentStackTraces: [ConsoleStackTracePayload] = []
    ) {
        self.callFrames = callFrames
        self.topCallFrameIsBoundary = topCallFrameIsBoundary
        self.truncated = truncated
        self.parentStackTraces = parentStackTraces
    }

    private enum CodingKeys: String, CodingKey {
        case callFrames
        case topCallFrameIsBoundary
        case truncated
        case parentStackTrace
        case parentStackTraces
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callFrames = try container.decode([ConsoleCallFramePayload].self, forKey: .callFrames)
        topCallFrameIsBoundary = try container.decodeIfPresent(Bool.self, forKey: .topCallFrameIsBoundary)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated)
        if let parentStackTrace = try container.decodeIfPresent(ConsoleStackTracePayload.self, forKey: .parentStackTrace) {
            parentStackTraces = [parentStackTrace]
        } else {
            parentStackTraces = try container.decodeIfPresent([ConsoleStackTracePayload].self, forKey: .parentStackTraces) ?? []
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callFrames, forKey: .callFrames)
        try container.encodeIfPresent(topCallFrameIsBoundary, forKey: .topCallFrameIsBoundary)
        try container.encodeIfPresent(truncated, forKey: .truncated)
        if parentStackTraces.count == 1 {
            try container.encode(parentStackTraces[0], forKey: .parentStackTrace)
        } else if parentStackTraces.isEmpty == false {
            try container.encode(parentStackTraces, forKey: .parentStackTraces)
        }
    }
}
