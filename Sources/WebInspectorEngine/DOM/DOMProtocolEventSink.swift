import Foundation
import WebInspectorCore

@MainActor
package protocol DOMProtocolEventSink: AnyObject {
    func domDidReceiveProtocolEvent(method: String, paramsData: Data)
}
