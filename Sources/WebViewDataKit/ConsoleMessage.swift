import Foundation
import Observation
import WebViewProxyKit

@MainActor
@Observable
public final class ConsoleMessage: Identifiable, WebViewFetchableModel {
    public struct ID: Comparable, Hashable, Sendable {
        package let ordinal: Int

        package init(_ ordinal: Int) {
            self.ordinal = ordinal
        }

        public static func < (lhs: ID, rhs: ID) -> Bool {
            lhs.ordinal < rhs.ordinal
        }
    }

    public let id: ID
    public private(set) var source: Console.Source
    public private(set) var level: Console.Level
    public private(set) var kind: Console.Kind?
    public private(set) var text: String
    public private(set) var url: String?
    public private(set) var line: Int?
    public private(set) var column: Int?
    public private(set) var repeatCount: Int
    public private(set) var parameters: [RuntimeObject]
    public private(set) var stackTrace: Console.StackTrace?
    public private(set) var networkRequestID: NetworkRequest.ID?
    public private(set) var timestamp: Double?

    package init(id: ID, message: Console.Message, parameters: [RuntimeObject]) {
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
    }

    package func updateRepeatCount(_ count: Int, timestamp: Double?) {
        repeatCount = count
        self.timestamp = timestamp
    }
}
