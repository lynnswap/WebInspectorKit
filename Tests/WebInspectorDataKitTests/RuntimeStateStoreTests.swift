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
            sourceTargetID: WebInspectorTarget.ID("page"),
            isolation: self
        )
        return (store.executionContexts.count, store.selectedContext?.name)
    }
}

@Test
func runtimeStateStoreFollowsCustomActorWithoutRetainingIt() async {
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
        sourceTargetID: WebInspectorTarget.ID("page"),
        isolation: MainActor.shared
    )
    let first = try #require(store.executionContexts.first)
    #expect(store.selectedContext === first)

    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: firstID,
            name: "First updated",
            kind: .user
        )),
        sourceTargetID: WebInspectorTarget.ID("page"),
        isolation: MainActor.shared
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
        sourceTargetID: WebInspectorTarget.ID("page"),
        isolation: MainActor.shared
    )
    let second = try #require(store.executionContexts.last)
    store.select(second, isolation: MainActor.shared)
    #expect(store.selectedContext === second)

    store.apply(
        .executionContextDestroyed(secondID),
        sourceTargetID: WebInspectorTarget.ID("page"),
        isolation: MainActor.shared
    )
    #expect(store.executionContexts == [first])
    #expect(store.selectedContext === first)
}

@MainActor
@Test
func runtimeStateStoreRemovesOwnershipOnlyForTheRegisteredObjectIdentity() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = RuntimeStateStore()
    let remoteObject = Runtime.RemoteObject(
        id: Runtime.RemoteObject.ID("shared-id"),
        kind: .object,
        description: "registered"
    )
    let registered = store.registerConsoleParameter(
        remoteObject,
        modelContext: context,
        isolation: MainActor.shared
    )
    let impostor = RuntimeObject(
        id: registered.id,
        remoteObject: remoteObject,
        modelContext: context
    )

    store.removeConsoleOwnership(from: [impostor], isolation: MainActor.shared)
    #expect(try store.objectBinding(for: registered, isolation: MainActor.shared)?.remoteID == remoteObject.id)

    store.removeConsoleOwnership(from: [registered], isolation: MainActor.shared)
    #expect(throws: WebInspectorProxyError.disconnected(
        "RuntimeObject is not registered in this WebInspectorContext."
    )) {
        try store.objectBinding(for: registered, isolation: MainActor.shared)
    }
}

@MainActor
@Test
func runtimeStateStorePreservesClientOwnershipAfterConsoleOwnershipEnds() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = RuntimeStateStore()
    let objectID = Runtime.RemoteObject.ID("client-and-console")
    let consoleObject = store.registerConsoleParameter(
        Runtime.RemoteObject(id: objectID, kind: .object, description: "console"),
        modelContext: context,
        isolation: MainActor.shared
    )
    let binding = try store.evaluationBinding(for: nil, isolation: MainActor.shared)
    let evaluation = try store.finishEvaluation(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: objectID, kind: .object, description: "client")
        ),
        binding: binding,
        modelContext: context,
        isolation: MainActor.shared
    )

    #expect(evaluation.object === consoleObject)
    #expect(consoleObject.description == "client")

    store.removeConsoleOwnership(from: [consoleObject], isolation: MainActor.shared)
    #expect(try store.objectBinding(for: consoleObject, isolation: MainActor.shared)?.remoteID == objectID)
}

@MainActor
@Test
func runtimeStateStoreTargetClearRemovesObjectsWithoutExecutionContexts() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = RuntimeStateStore()
    let pageTargetID = WebInspectorTarget.ID("page")
    let frameTargetID = WebInspectorTarget.ID("frame")
    let pageObject = store.registerConsoleParameter(
        Runtime.RemoteObject(
            id: Runtime.RemoteObject.ID("page-object", scopedToTargetRawValue: pageTargetID.rawValue),
            kind: .object
        ),
        modelContext: context,
        isolation: MainActor.shared
    )
    let frameObject = store.registerConsoleParameter(
        Runtime.RemoteObject(
            id: Runtime.RemoteObject.ID("frame-object", scopedToTargetRawValue: frameTargetID.rawValue),
            kind: .object
        ),
        modelContext: context,
        isolation: MainActor.shared
    )
    #expect(store.executionContexts.isEmpty)

    store.apply(
        .executionContextsCleared(target: frameTargetID),
        sourceTargetID: pageTargetID,
        isolation: MainActor.shared
    )

    #expect(try store.objectBinding(for: pageObject, isolation: MainActor.shared) != nil)
    #expect(throws: WebInspectorProxyError.disconnected(
        "RuntimeObject is not registered in this WebInspectorContext."
    )) {
        try store.objectBinding(for: frameObject, isolation: MainActor.shared)
    }
}

@MainActor
@Test
func runtimeStateStoreTargetClearPreservesOtherTargetContexts() throws {
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
        sourceTargetID: pageTargetID,
        isolation: MainActor.shared
    )
    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: frameContextID,
            name: "Frame",
            kind: .normal
        )),
        sourceTargetID: frameTargetID,
        isolation: MainActor.shared
    )
    let pageContext = try #require(store.executionContexts.first)
    let frameContext = try #require(store.executionContexts.last)
    store.select(frameContext, isolation: MainActor.shared)

    store.apply(
        .executionContextsCleared(target: frameTargetID),
        sourceTargetID: pageTargetID,
        isolation: MainActor.shared
    )

    #expect(store.executionContexts.count == 1)
    #expect(store.executionContexts.first === pageContext)
    #expect(store.selectedContext === pageContext)
}

@MainActor
@Test
func runtimeStateStoreOldPointerCannotRemoveSameRemoteIDReplacement() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = RuntimeStateStore()
    let remoteID = Runtime.RemoteObject.ID("reused-remote-id")
    let oldObject = store.registerConsoleParameter(
        Runtime.RemoteObject(id: remoteID, kind: .object, description: "old"),
        modelContext: context,
        isolation: MainActor.shared
    )

    store.reset(isolation: MainActor.shared)

    let replacement = store.registerConsoleParameter(
        Runtime.RemoteObject(id: remoteID, kind: .object, description: "replacement"),
        modelContext: context,
        isolation: MainActor.shared
    )
    #expect(replacement !== oldObject)
    store.removeConsoleOwnership(from: [oldObject], isolation: MainActor.shared)

    #expect(try store.objectBinding(for: replacement, isolation: MainActor.shared)?.remoteID == remoteID)
    #expect(throws: WebInspectorProxyError.disconnected(
        "RuntimeObject is not registered in this WebInspectorContext."
    )) {
        try store.objectBinding(for: oldObject, isolation: MainActor.shared)
    }
}

@MainActor
@Test
func runtimeStateStoreNeverReusesSyntheticIdentityAfterReset() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = RuntimeStateStore()
    let first = store.registerConsoleParameter(
        Runtime.RemoteObject(id: nil, kind: .number, value: .number(1)),
        modelContext: context,
        isolation: MainActor.shared
    )

    store.reset(isolation: MainActor.shared)

    let second = store.registerConsoleParameter(
        Runtime.RemoteObject(id: nil, kind: .number, value: .number(2)),
        modelContext: context,
        isolation: MainActor.shared
    )
    #expect(first.id != second.id)
    #expect(first !== second)
}

@MainActor
@Test
func runtimeStateStoreRejectsDefaultEvaluationReplyAfterFullReset() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = RuntimeStateStore()
    let binding = try store.evaluationBinding(for: nil, isolation: MainActor.shared)

    store.reset(isolation: MainActor.shared)

    #expect(throws: WebInspectorProxyError.disconnected(
        "Runtime evaluation target is no longer current in this WebInspectorContext."
    )) {
        try store.finishEvaluation(
            Runtime.EvaluationResult(object: Runtime.RemoteObject(id: nil, kind: .undefined)),
            binding: binding,
            modelContext: context,
            isolation: MainActor.shared
        )
    }
}

@MainActor
@Test
func runtimeStateStoreDoesNotRetainRuntimeObjectModelContext() {
    let store = RuntimeStateStore()
    weak var releasedContext: WebInspectorContext?
    let object: RuntimeObject

    do {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        releasedContext = context
        object = store.registerConsoleParameter(
            Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("weak-model-context"),
                kind: .object
            ),
            modelContext: context,
            isolation: MainActor.shared
        )
        #expect(object.modelContext === context)
    }

    #expect(releasedContext == nil)
    #expect(object.modelContext == nil)
}

@MainActor
@Test
func runtimeStateStoreRejectsEvaluationReplyAfterContextIdentityReplacement() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let store = RuntimeStateStore()
    let contextID = Runtime.ExecutionContext.ID("reused-context")
    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Before",
            kind: .normal
        )),
        sourceTargetID: WebInspectorTarget.ID("page"),
        isolation: MainActor.shared
    )
    let original = try #require(store.executionContexts.first)
    let binding = try store.evaluationBinding(for: original, isolation: MainActor.shared)

    store.apply(
        .executionContextDestroyed(contextID),
        sourceTargetID: WebInspectorTarget.ID("page"),
        isolation: MainActor.shared
    )
    store.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "After",
            kind: .normal
        )),
        sourceTargetID: WebInspectorTarget.ID("page"),
        isolation: MainActor.shared
    )

    #expect(store.executionContexts.first !== original)
    #expect(throws: WebInspectorProxyError.disconnected(
        "RuntimeContext is not registered in this WebInspectorContext."
    )) {
        try store.finishEvaluation(
            Runtime.EvaluationResult(object: Runtime.RemoteObject(id: nil, kind: .undefined)),
            binding: binding,
            modelContext: context,
            isolation: MainActor.shared
        )
    }
}
