import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

private actor ReferenceValue {}

@Test
func anySendableValuePreservesReferenceIdentity() throws {
    let value = ReferenceValue()
    let erased = AnySendableValue(value)

    let restored = try #require(erased.cast(as: ReferenceValue.self))
    #expect(restored === value)
}

@Test
func anySendableValueReturnsNilForTheWrongType() {
    let erased = AnySendableValue(42)

    #expect(erased.cast(as: String.self) == nil)
}

@Test
func recordedCommandPreservesItsTypedPayload() throws {
    let nodeID = DOM.Node.ID("parent")
    let payload = DOM.RequestChildNodesPayload(id: nodeID, depth: 2)
    let command = WebInspectorProxyCommand<DOM.RequestChildNodesPayload, Void>(
        targetID: WebInspectorTarget.ID("page"),
        route: RoutingTargetID("page"),
        domain: .dom,
        method: "requestChildNodes",
        payload: payload
    )

    let recorded = RecordedCommand(command: command)
    let restored = try #require(
        recorded.payload.cast(as: DOM.RequestChildNodesPayload.self)
    )
    #expect(restored.id == nodeID)
    #expect(restored.depth == 2)
}
