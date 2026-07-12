import Foundation
import Synchronization

package enum WebInspectorCommandAuthority: Equatable, Sendable {
    case direct
    case modelFeed(ConnectionModelCommandAuthorization)
}

package struct ConnectionModelCommandAuthorization: Equatable, Sendable {
    package struct Document: Equatable, Sendable {
        package let targetID: WebInspectorTarget.ID
        package let epoch: ModelDOMBindingEpoch

        package init(
            targetID: WebInspectorTarget.ID,
            epoch: ModelDOMBindingEpoch
        ) {
            self.targetID = targetID
            self.epoch = epoch
        }
    }

    package let feedID: ConnectionModelFeedID
    package let generation: WebInspectorPage.Generation
    package let document: Document?

    package init(
        feedID: ConnectionModelFeedID,
        generation: WebInspectorPage.Generation,
        document: Document? = nil
    ) {
        self.feedID = feedID
        self.generation = generation
        self.document = document
    }
}

package enum ConnectionModelCommandError: Error, Equatable, Sendable {
    case notActive
    case domainNotConfigured(WebInspectorProxyDomain)
    case internalCommand(domain: WebInspectorProxyDomain, method: String)
    case documentAuthorizationRequired(WebInspectorProxyDomain)
}

/// Lets value-typed child handles find their connection without becoming a
/// second owner of its asynchronous close lifecycle.
package final class WebInspectorProxyReference: Sendable {
    private struct State {
        weak var proxy: WebInspectorProxy?
    }

    private let state: Mutex<State>

    package init(_ proxy: WebInspectorProxy) {
        state = Mutex(State(proxy: proxy))
    }

    package func resolve() -> WebInspectorProxy? {
        state.withLock { state in
            state.proxy
        }
    }
}
