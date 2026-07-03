import Foundation

package enum Inspector {
    package enum Event: Sendable {
        case inspect(Runtime.RemoteObject, hints: Runtime.JSONValue?)
        case unknown(RawEvent)
    }
}
