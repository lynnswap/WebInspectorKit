import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private actor RuntimeStateStoreIsolationProbe {
    private let store = RuntimeStateStore()

    func exercise() -> (contextCount: Int, selectedName: String?) {
        store.apply(
            .executionContextCreated(Runtime.ExecutionContext(
                id: Runtime.ExecutionContext.ID("custom-actor-context"),
                name: "Custom actor",
                kind: .normal
            )),
            sourceTargetID: WebInspectorTarget.ID("page")
        )
        return (store.executionContexts.count, store.selectedContext?.name)
    }
}

@Test
func runtimeStateStoreFollowsItsCallerActorWithoutRetainingIt() async {
    var probe: RuntimeStateStoreIsolationProbe? = RuntimeStateStoreIsolationProbe()
    weak let releasedProbe = probe

    let values = await probe?.exercise()
    #expect(values?.contextCount == 1)
    #expect(values?.selectedName == "Custom actor")

    probe = nil
    for _ in 0..<100 where releasedProbe != nil {
        await Task.yield()
    }
    #expect(releasedProbe == nil)
}

@MainActor
@Test
func runtimeStateStoreOwnsContextIdentityOrderAndSelection() throws {
    let store = RuntimeStateStore()
    let firstID = Runtime.ExecutionContext.ID("first")
    let secondID = Runtime.ExecutionContext.ID("second")

    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: firstID,
            name: "First",
            kind: .normal
        )),
        sourceTargetID: WebInspectorTarget.ID("page")
    )
    let first = try #require(store.executionContexts.first)
    #expect(store.selectedContext === first)

    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: firstID,
            name: "First updated",
            kind: .user
        )),
        sourceTargetID: WebInspectorTarget.ID("page")
    )
    #expect(store.executionContexts == [first])
    #expect(first.name == "First updated")
    #expect(first.kind == .user)

    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: secondID,
            name: "Second",
            kind: .normal
        )),
        sourceTargetID: WebInspectorTarget.ID("page")
    )
    let second = try #require(store.executionContexts.last)
    store.select(second)
    #expect(store.selectedContext === second)

    store.apply(
        .executionContextDestroyed(secondID),
        sourceTargetID: WebInspectorTarget.ID("page")
    )
    #expect(store.executionContexts == [first])
    #expect(store.selectedContext === first)
}

@MainActor
@Test
func runtimeStateStoreKeepsGroupOwnershipAfterConsoleOwnershipEnds() throws {
    let store = RuntimeStateStore()
    let groupID = store.createGroupID()
    let remoteID = Runtime.RemoteObject.ID("shared")
    let consoleObject = store.registerConsoleParameter(
        Runtime.RemoteObject(id: remoteID, kind: .object, description: "console")
    )
    let binding = try store.evaluationBinding(for: nil)
    let evaluation = try store.finishEvaluation(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: remoteID, kind: .object, description: "group")
        ),
        binding: binding,
        groupID: groupID
    )

    #expect(evaluation.object === consoleObject)
    #expect(consoleObject.description == "group")
    store.removeConsoleOwnership(from: [consoleObject])
    #expect(try store.objectBinding(for: consoleObject, groupID: groupID)?.remoteID == remoteID)

    store.invalidateGroup(groupID)
    #expect(throws: WebInspectorModelError.staleModel) {
        try store.objectBinding(for: consoleObject, groupID: groupID)
    }
}

@MainActor
@Test
func runtimeStateStoreOldPointerCannotRemoveSameRemoteIDReplacement() throws {
    let store = RuntimeStateStore()
    let remoteID = Runtime.RemoteObject.ID("reused-remote-id")
    let oldObject = store.registerConsoleParameter(
        Runtime.RemoteObject(id: remoteID, kind: .object, description: "old")
    )

    store.reset()
    let groupID = store.createGroupID()
    let replacement = store.registerConsoleParameter(
        Runtime.RemoteObject(id: remoteID, kind: .object, description: "replacement")
    )
    let binding = try store.evaluationBinding(for: nil)
    _ = try store.finishEvaluation(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: remoteID, kind: .object, description: "group-owned")
        ),
        binding: binding,
        groupID: groupID
    )

    #expect(replacement !== oldObject)
    store.removeConsoleOwnership(from: [oldObject])
    #expect(try store.objectBinding(for: replacement, groupID: groupID)?.remoteID == remoteID)
}

@MainActor
@Test
func runtimeStateStoreNeverReusesSyntheticOrGroupIdentityAfterReset() {
    let store = RuntimeStateStore()
    let firstGroup = store.createGroupID()
    let first = store.registerConsoleParameter(
        Runtime.RemoteObject(id: nil, kind: .number, value: .number(1))
    )

    store.reset()

    let secondGroup = store.createGroupID()
    let second = store.registerConsoleParameter(
        Runtime.RemoteObject(id: nil, kind: .number, value: .number(2))
    )
    #expect(first.id != second.id)
    #expect(firstGroup != secondGroup)
}

@MainActor
@Test
func runtimeStateStoreRejectsDefaultEvaluationReplyAfterFullReset() throws {
    let store = RuntimeStateStore()
    let oldBinding = try store.evaluationBinding(for: nil)
    _ = store.createGroupID()

    store.reset()
    let replacementGroup = store.createGroupID()

    #expect(throws: WebInspectorProxyError.disconnected(
        "Runtime evaluation target is no longer current in this WebInspectorModelContext."
    )) {
        try store.finishEvaluation(
            Runtime.EvaluationResult(
                object: Runtime.RemoteObject(id: nil, kind: .undefined)
            ),
            binding: oldBinding,
            groupID: replacementGroup
        )
    }
}

@MainActor
@Test
func runtimeStateStoreTargetClearPreservesOtherTargetState() throws {
    let store = RuntimeStateStore()
    let pageTargetID = WebInspectorTarget.ID("page")
    let frameTargetID = WebInspectorTarget.ID("frame")
    let pageContextID = Runtime.ExecutionContext.ID(
        "context",
        scopedToTargetRawValue: pageTargetID.rawValue
    )
    let frameContextID = Runtime.ExecutionContext.ID(
        "context",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: pageContextID,
            name: "Page",
            kind: .normal
        )),
        sourceTargetID: pageTargetID
    )
    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: frameContextID,
            name: "Frame",
            kind: .normal
        )),
        sourceTargetID: frameTargetID
    )
    let pageContext = try #require(store.executionContexts.first)
    let frameContext = try #require(store.executionContexts.last)
    store.select(frameContext)

    let groupID = store.createGroupID()
    let binding = try store.evaluationBinding(for: nil)
    let pageObject = try store.finishEvaluation(
        Runtime.EvaluationResult(object: Runtime.RemoteObject(
            id: Runtime.RemoteObject.ID(
                "page-object",
                scopedToTargetRawValue: pageTargetID.rawValue
            ),
            kind: .object
        )),
        binding: binding,
        groupID: groupID
    ).object
    let frameObject = try store.finishEvaluation(
        Runtime.EvaluationResult(object: Runtime.RemoteObject(
            id: Runtime.RemoteObject.ID(
                "frame-object",
                scopedToTargetRawValue: frameTargetID.rawValue
            ),
            kind: .object
        )),
        binding: binding,
        groupID: groupID
    ).object

    store.apply(
        .executionContextsCleared(target: frameTargetID),
        sourceTargetID: pageTargetID
    )

    #expect(store.executionContexts.count == 1)
    #expect(store.executionContexts.first === pageContext)
    #expect(store.selectedContext === pageContext)
    #expect(try store.objectBinding(for: pageObject, groupID: groupID) != nil)
    #expect(throws: WebInspectorProxyError.disconnected(
        "RuntimeObject is not registered in this WebInspectorModelContext."
    )) {
        try store.objectBinding(for: frameObject, groupID: groupID)
    }
}

@MainActor
@Test
func runtimeStateStoreRejectsEvaluationReplyAfterContextIdentityReplacement() throws {
    let store = RuntimeStateStore()
    let contextID = Runtime.ExecutionContext.ID("reused-context")
    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Before",
            kind: .normal
        )),
        sourceTargetID: WebInspectorTarget.ID("page")
    )
    let original = try #require(store.executionContexts.first)
    let binding = try store.evaluationBinding(for: original)

    store.apply(
        .executionContextDestroyed(contextID),
        sourceTargetID: WebInspectorTarget.ID("page")
    )
    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "After",
            kind: .normal
        )),
        sourceTargetID: WebInspectorTarget.ID("page")
    )
    let groupID = store.createGroupID()

    #expect(store.executionContexts.first !== original)
    #expect(throws: WebInspectorProxyError.disconnected(
        "RuntimeContext is not registered in this WebInspectorModelContext."
    )) {
        try store.finishEvaluation(
            Runtime.EvaluationResult(
                object: Runtime.RemoteObject(id: nil, kind: .undefined)
            ),
            binding: binding,
            groupID: groupID
        )
    }
}
