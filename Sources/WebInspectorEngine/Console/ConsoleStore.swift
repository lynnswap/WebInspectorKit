import Foundation
import Observation

public enum WIConsoleClearReason: String, Decodable, Sendable {
    case consoleAPI = "console-api"
    case frontend
    case mainFrameNavigation = "main-frame-navigation"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .frontend
    }
}

@MainActor
@Observable
public final class ConsoleStore {
    public init() {}

    public private(set) var entries: [WIConsoleEntry] = []
    package private(set) var entriesGeneration: UInt64 = 0

    package func append(_ entry: WIConsoleEntry) {
        entries.append(entry)
        markEntriesChanged()
    }

    package func clear(reason: WIConsoleClearReason? = nil) {
        _ = reason
        guard entries.isEmpty == false else {
            return
        }
        entries.removeAll(keepingCapacity: false)
        markEntriesChanged()
    }

    package func updateRepeatCount(
        forLastEntry count: Int,
        timestamp: Date?
    ) {
        guard let lastEntry = entries.last else {
            return
        }
        lastEntry.updateRepeatCount(count, timestamp: timestamp)
        markEntriesChanged()
    }

    package func reset() {
        clear(reason: nil)
    }
}

private extension ConsoleStore {
    func markEntriesChanged() {
        entriesGeneration &+= 1
    }
}
