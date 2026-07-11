import Foundation

package struct ConsoleMessageRecordInput: Hashable, Sendable {
    package var id: ConsoleMessage.ID
    package var orderIndex: Int
    package var sourceRawValue: String
    package var levelRawValue: String
    package var kindRawValue: String?
    package var text: String
    package var url: String?
    package var line: Int?
    package var column: Int?
    package var repeatCount: Int
    package var timestamp: Double?

    package init(message: ConsoleMessage, orderIndex: Int) {
        id = message.id
        self.orderIndex = orderIndex
        sourceRawValue = message.source.rawValue
        levelRawValue = message.level.rawValue
        kindRawValue = message.kind?.rawValue
        text = message.text
        url = message.url
        line = message.line
        column = message.column
        repeatCount = message.repeatCount
        timestamp = message.timestamp
    }
}

package struct ConsoleMessageRecord: Hashable, Sendable {
    package var id: ConsoleMessage.ID
    package var orderIndex: Int
    package var sourceRawValue: String
    package var levelRawValue: String
    package var kindRawValue: String?
    package var text: String
    package var url: String?
    package var line: Int?
    package var column: Int?
    package var repeatCount: Int
    package var timestamp: Double?

    package init(input: ConsoleMessageRecordInput) {
        id = input.id
        orderIndex = input.orderIndex
        sourceRawValue = input.sourceRawValue
        levelRawValue = input.levelRawValue
        kindRawValue = input.kindRawValue
        text = input.text
        url = input.url
        line = input.line
        column = input.column
        repeatCount = input.repeatCount
        timestamp = input.timestamp
    }

    package init(message: ConsoleMessage, orderIndex: Int) {
        self.init(input: ConsoleMessageRecordInput(message: message, orderIndex: orderIndex))
    }
}
