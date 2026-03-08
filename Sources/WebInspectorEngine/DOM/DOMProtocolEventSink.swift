import Foundation

@MainActor
package protocol DOMProtocolEventSink: AnyObject {
    func domDidReceiveProtocolEvent(method: String, paramsData: Data)
}
