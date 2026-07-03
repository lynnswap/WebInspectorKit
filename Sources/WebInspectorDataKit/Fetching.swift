import Foundation
import Observation

public struct WebInspectorFetchDescriptor<Model: WebInspectorFetchableModel>: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case allRequests
        case allConsoleMessages
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }
}

extension WebInspectorFetchDescriptor where Model == NetworkRequest {
    public static var allRequests: Self {
        Self(kind: .allRequests)
    }
}

extension WebInspectorFetchDescriptor where Model == ConsoleMessage {
    public static var allConsoleMessages: Self {
        Self(kind: .allConsoleMessages)
    }
}

@Observable
public final class WebInspectorFetchedResults<Model: WebInspectorFetchableModel> {
    public private(set) var items: [Model]

    init(items: [Model] = []) {
        self.items = items
    }

    func setItems(_ items: [Model]) {
        self.items = items
    }
}
