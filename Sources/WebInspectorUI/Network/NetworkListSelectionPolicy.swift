import Foundation
import WebInspectorEngine

@MainActor
enum NetworkListSelectionPolicy {
    enum MissingSelectionBehavior: Sendable, Equatable {
        case none
        case firstEntry
    }

    static func resolvedSelection(
        current selectedEntry: NetworkEntry?,
        entries: [NetworkEntry],
        whenMissing missingSelectionBehavior: MissingSelectionBehavior = .firstEntry
    ) -> NetworkEntry? {
        guard !entries.isEmpty else {
            return nil
        }
        if let selectedEntry,
           let matchedEntry = entries.first(where: { $0.id == selectedEntry.id }) {
            return matchedEntry
        }
        switch missingSelectionBehavior {
        case .none:
            return nil
        case .firstEntry:
            return entries.first
        }
    }
}
