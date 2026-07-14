#if canImport(UIKit)
extension NetworkListViewController {
    struct SnapshotState {
        private(set) var applyingGeneration: UInt64?
        private var nextGeneration: UInt64 = 0

        var isApplying: Bool {
            applyingGeneration != nil
        }

        mutating func beginApplying() -> UInt64? {
            guard applyingGeneration == nil else { return nil }
            nextGeneration &+= 1
            applyingGeneration = nextGeneration
            return nextGeneration
        }

        mutating func finishApplying(generation: UInt64) -> Bool {
            guard applyingGeneration == generation else { return false }
            applyingGeneration = nil
            return true
        }
    }
}
#endif
