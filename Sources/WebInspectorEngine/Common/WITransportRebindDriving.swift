import WebKit

@MainActor
protocol DOMTransportRebindDriving: AnyObject {
    func prepareForTransportRebind()
    func resumeAfterTransportRebind()
}

@MainActor
protocol NetworkTransportRebindDriving: AnyObject {
    func prepareForTransportRebind()
    func resumeAfterTransportRebind()
}
