@MainActor
package protocol WIDOMUIBridge: AnyObject {
    func prepareForSelection(using runtime: WIDOMRuntime)
    func finishSelection(using runtime: WIDOMRuntime)
    func copyToPasteboard(_ text: String)
}
