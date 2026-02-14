@MainActor
public protocol DOMBundleSink: AnyObject {
    func domDidEmit(bundle: DOMBundle)
}

public struct DOMBundle: Sendable {
    public let rawJSON: String

    public init(rawJSON: String) {
        self.rawJSON = rawJSON
    }
}
