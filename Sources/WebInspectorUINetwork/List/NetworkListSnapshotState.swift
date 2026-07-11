#if canImport(UIKit)
extension NetworkListViewController {
    struct SnapshotState {
        private(set) var applyingGeneration: UInt64?
        private var nextGeneration: UInt64 = 0

        var isApplying: Bool {
            applyingGeneration != nil
        }

        mutating func beginApplying() -> UInt64 {
            precondition(
                applyingGeneration == nil,
                "Network list cannot start a second snapshot apply before completion."
            )
            precondition(
                nextGeneration < .max,
                "Network list snapshot apply generation overflowed."
            )
            nextGeneration += 1
            applyingGeneration = nextGeneration
            return nextGeneration
        }

        mutating func finishApplying(generation: UInt64) {
            precondition(
                applyingGeneration == generation,
                "Network list snapshot completion must match the active apply generation."
            )
            applyingGeneration = nil
        }
    }
}
#endif
