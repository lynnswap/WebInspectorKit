import Foundation

@MainActor
package protocol WIDOMProtocolEventSink: AnyObject {
    func domDidReceiveProtocolEvent(method: String, paramsData: Data, paramsObject: Any?)
}

package extension WIDOMProtocolEventSink {
    func domDidReceiveProtocolEvent(method: String, paramsData: Data) {
        domDidReceiveProtocolEvent(method: method, paramsData: paramsData, paramsObject: nil)
    }
}
