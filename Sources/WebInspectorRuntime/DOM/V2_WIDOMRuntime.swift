import Observation
import WebInspectorEngine

@MainActor
@Observable
public final class V2_WIDOMRuntime {
    public var rootNode: DOMNodeModel?
    public var selectedNode: DOMNodeModel?

    public init(
        rootNode: DOMNodeModel? = nil,
        selectedNode: DOMNodeModel? = nil
    ) {
        self.rootNode = rootNode
        self.selectedNode = selectedNode
    }
}
