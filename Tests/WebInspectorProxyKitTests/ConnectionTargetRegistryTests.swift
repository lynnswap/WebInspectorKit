import Testing
@testable import WebInspectorProxyKit

@Test
func targetKindUsesTheProtocolTypeAndDeliveryTopology() {
    let registry = ConnectionTargetRegistry()
    #expect(registry.targetKind(
        protocolType: "frame",
        parentTargetID: nil,
        parentFrameID: nil
    ) == .frame)
    #expect(registry.targetKind(
        protocolType: "web-page",
        parentTargetID: ProtocolTarget.ID("page-main"),
        parentFrameID: nil
    ) == .frame)
    #expect(registry.targetKind(
        protocolType: "page",
        parentTargetID: nil,
        parentFrameID: nil
    ) == .page)
}

@Test
func topLevelCommitRetargetsTheLogicalPage() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-old",
        kind: .page
    ))
    registry.insert(target(
        "page-new",
        kind: .page,
        isProvisional: true
    ))

    let mutation = registry.commit(
        old: ProtocolTarget.ID("page-old"),
        new: ProtocolTarget.ID("page-new")
    )

    #expect(mutation.bindingChanged)
    #expect(mutation.retiredTargetID == ProtocolTarget.ID("page-old"))
    #expect(mutation.committedTargetID == ProtocolTarget.ID("page-new"))
    #expect(registry.currentPageID == ProtocolTarget.ID("page-new"))
    #expect(registry.record(for: ProtocolTarget.ID("page-new"))?.isProvisional == false)
    #expect(registry.record(for: ProtocolTarget.ID("page-old")) == nil)
}

@Test
func subframeCommitPreservesTheLogicalPageAndItsPhysicalTarget() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-main",
        kind: .page
    ))
    registry.insert(target(
        "frame-old",
        kind: .frame
    ))
    registry.insert(target(
        "frame-new",
        kind: .frame,
        isProvisional: true
    ))

    let mutation = registry.commit(
        old: ProtocolTarget.ID("frame-old"),
        new: ProtocolTarget.ID("frame-new")
    )

    #expect(!mutation.bindingChanged)
    #expect(mutation.retiredTargetID == ProtocolTarget.ID("frame-old"))
    #expect(mutation.committedTargetID == ProtocolTarget.ID("frame-new"))
    #expect(registry.currentPageID == ProtocolTarget.ID("page-main"))
    #expect(registry.record(for: ProtocolTarget.ID("page-main")) != nil)
    #expect(registry.record(for: ProtocolTarget.ID("frame-old")) == nil)
    #expect(registry.record(for: ProtocolTarget.ID("frame-new"))?.isProvisional == false)
}

@Test
func currentPageSelectionIncludesFrameTargetsButNotWorkers() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-main",
        kind: .page
    ))
    registry.insert(target(
        "frame-one",
        kind: .frame
    ))
    registry.insert(target(
        "worker-one",
        kind: .worker,
        parentTargetID: "page-main"
    ))

    #expect(registry.selectedTargets(for: .currentPage) == [
        ProtocolTarget.ID("page-main"),
        ProtocolTarget.ID("frame-one"),
    ])
}

@Test
func currentPageSelectionExcludesAProvisionalFrameUntilCommit() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-main",
        kind: .page
    ))
    registry.insert(target(
        "frame-old",
        kind: .frame
    ))
    registry.insert(target(
        "frame-new",
        kind: .frame,
        isProvisional: true
    ))

    #expect(registry.selectedTargets(for: .currentPage) == [
        ProtocolTarget.ID("page-main"),
        ProtocolTarget.ID("frame-old"),
    ])
    _ = registry.commit(
        old: ProtocolTarget.ID("frame-old"),
        new: ProtocolTarget.ID("frame-new")
    )
    #expect(registry.selectedTargets(for: .currentPage) == [
        ProtocolTarget.ID("page-main"),
        ProtocolTarget.ID("frame-new"),
    ])
}

@Test
func currentPageDescendantSelectionFollowsNestedTargetDelivery() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target("page-main", kind: .page))
    registry.insert(target("frame-one", kind: .frame))
    registry.insert(target(
        "worker-one",
        kind: .worker,
        parentTargetID: "frame-one"
    ))
    registry.insert(target("service-worker", kind: .serviceWorker))

    let selection = WebInspectorTargetSelectionPolicy.descendants(
        kinds: [.frame, .worker, .serviceWorker],
        includingAnchor: true
    )
    #expect(registry.selectedTargets(for: selection) == [
        ProtocolTarget.ID("page-main"),
        ProtocolTarget.ID("frame-one"),
        ProtocolTarget.ID("worker-one"),
    ])
}

private func target(
    _ id: String,
    kind: ProtocolTarget.Kind,
    parentTargetID: String? = nil,
    frameID: String? = nil,
    parentFrameID: String? = nil,
    isProvisional: Bool = false
) -> ProtocolTarget.Record {
    ProtocolTarget.Record(
        id: ProtocolTarget.ID(id),
        kind: kind,
        parentTargetID: parentTargetID.map { ProtocolTarget.ID($0) },
        frameID: frameID.map { ProtocolFrame.ID($0) },
        parentFrameID: parentFrameID.map { ProtocolFrame.ID($0) },
        isProvisional: isProvisional,
        isPaused: false
    )
}
