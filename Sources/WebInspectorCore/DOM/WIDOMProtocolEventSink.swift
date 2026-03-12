import Foundation

@MainActor
package protocol WIDOMProtocolEventSink: AnyObject {
    func domDidReceiveProtocolEvent(method: String, paramsData: Data)
}
