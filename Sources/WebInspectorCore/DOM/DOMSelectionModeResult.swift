public struct DOMSelectionModeResult: Decodable, Sendable {
    public let cancelled: Bool
    public let requiredDepth: Int

    public init(cancelled: Bool, requiredDepth: Int) {
        self.cancelled = cancelled
        self.requiredDepth = requiredDepth
    }
}
