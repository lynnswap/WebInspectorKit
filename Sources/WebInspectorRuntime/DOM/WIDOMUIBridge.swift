@MainActor
package protocol WIDOMUIBridge: AnyObject {
    func prepareForSelection(using session: DOMSession)
    func finishSelection(using session: DOMSession)
    func copyToPasteboard(_ text: String)
}
