import Foundation

package enum Inspector {
    package struct EventOrigin: Sendable {
        package let targetID: WebInspectorTarget.ID
        package let route: RoutingTargetID

        package init(targetID: WebInspectorTarget.ID, route: RoutingTargetID) {
            self.targetID = targetID
            self.route = route
        }
    }

    package enum Event: Sendable {
        case inspect(Runtime.RemoteObject, hints: Runtime.JSONValue?, origin: EventOrigin?)
        case unknown(RawEvent)
    }
}
