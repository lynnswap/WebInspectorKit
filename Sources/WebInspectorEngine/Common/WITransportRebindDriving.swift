import WebKit

@MainActor
package protocol DOMTransportRebindDriving: AnyObject {
    func prepareForTransportRebind()
    func resumeAfterTransportRebind()
}

@MainActor
package protocol NetworkTransportRebindDriving: AnyObject {
    func prepareForTransportRebind()
    func resumeAfterTransportRebind()
}
