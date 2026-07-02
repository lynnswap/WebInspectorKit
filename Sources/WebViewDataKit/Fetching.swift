import Foundation
import Observation

public struct WebViewFetchDescriptor<Model: WebViewFetchableModel>: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case allRequests
        case allConsoleMessages
    }

    package let kind: Kind

    package init(kind: Kind) {
        self.kind = kind
    }
}

extension WebViewFetchDescriptor where Model == NetworkRequest {
    public static var allRequests: Self {
        Self(kind: .allRequests)
    }
}

extension WebViewFetchDescriptor where Model == ConsoleMessage {
    public static var allConsoleMessages: Self {
        Self(kind: .allConsoleMessages)
    }
}

@MainActor
@Observable
public final class WebViewFetchedResults<Model: WebViewFetchableModel> {
    public private(set) var items: [Model]

    package init(items: [Model] = []) {
        self.items = items
    }

    package func setItems(_ items: [Model]) {
        self.items = items
    }
}

@MainActor
public final class WebViewFetchedResultsController<Model: WebViewFetchableModel> {
    public let fetchedResults: WebViewFetchedResults<Model>

    package init(fetchedResults: WebViewFetchedResults<Model>) {
        self.fetchedResults = fetchedResults
    }
}
