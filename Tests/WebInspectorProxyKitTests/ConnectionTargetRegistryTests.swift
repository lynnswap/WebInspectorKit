import Testing
@testable import WebInspectorProxyKit

@Test
func targetKindUsesFrameTopologyForLegacyPageType() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-main",
        kind: .page,
        frameID: "main-frame"
    ))

    #expect(registry.targetKind(
        protocolType: "web-page",
        frameID: ProtocolFrame.ID("child-frame"),
        parentFrameID: ProtocolFrame.ID("main-frame"),
        isProvisional: false
    ) == .frame)
    #expect(registry.targetKind(
        protocolType: "page",
        frameID: ProtocolFrame.ID("other-frame"),
        parentFrameID: nil,
        isProvisional: false
    ) == .frame)
    #expect(registry.targetKind(
        protocolType: "page",
        frameID: ProtocolFrame.ID("replacement-main-frame"),
        parentFrameID: nil,
        isProvisional: true
    ) == .page)
}

@Test
func topLevelCommitRetargetsTheLogicalPage() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-old",
        kind: .page,
        frameID: "old-main-frame"
    ))
    registry.insert(target(
        "page-new",
        kind: .page,
        frameID: "new-main-frame",
        isProvisional: true
    ))

    let mutation = registry.commit(
        old: ProtocolTarget.ID("page-old"),
        new: ProtocolTarget.ID("page-new")
    )

    #expect(mutation.bindingChanged)
    #expect(mutation.retiredTargetID == ProtocolTarget.ID("page-old"))
    #expect(registry.currentPageID == ProtocolTarget.ID("page-new"))
    #expect(registry.record(for: ProtocolTarget.ID("page-new"))?.isProvisional == false)
    #expect(registry.record(for: ProtocolTarget.ID("page-old")) == nil)
}

@Test
func subframeCommitPreservesTheLogicalPageAndItsPhysicalTarget() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-main",
        kind: .page,
        frameID: "main-frame"
    ))
    registry.insert(target(
        "frame-new",
        kind: .frame,
        frameID: "child-frame",
        parentFrameID: "main-frame",
        isProvisional: true
    ))

    let mutation = registry.commit(
        old: ProtocolTarget.ID("page-main"),
        new: ProtocolTarget.ID("frame-new")
    )

    #expect(!mutation.bindingChanged)
    #expect(mutation.retiredTargetID == nil)
    #expect(registry.currentPageID == ProtocolTarget.ID("page-main"))
    #expect(registry.record(for: ProtocolTarget.ID("page-main")) != nil)
    #expect(registry.record(for: ProtocolTarget.ID("frame-new"))?.isProvisional == false)
}

@Test
func currentPageSelectionIncludesFrameTargetsButNotWorkers() {
    var registry = ConnectionTargetRegistry()
    registry.insert(target(
        "page-main",
        kind: .page,
        frameID: "main-frame"
    ))
    registry.insert(target(
        "frame-one",
        kind: .frame,
        frameID: "child-frame",
        parentFrameID: "main-frame"
    ))
    registry.insert(target(
        "worker-one",
        kind: .worker,
        frameID: "main-frame"
    ))

    #expect(registry.selectedTargets(for: .currentPage) == [
        ProtocolTarget.ID("page-main"),
        ProtocolTarget.ID("frame-one"),
    ])
}

private func target(
    _ id: String,
    kind: ProtocolTarget.Kind,
    frameID: String?,
    parentFrameID: String? = nil,
    isProvisional: Bool = false
) -> ProtocolTarget.Record {
    ProtocolTarget.Record(
        id: ProtocolTarget.ID(id),
        kind: kind,
        frameID: frameID.map { ProtocolFrame.ID($0) },
        parentFrameID: parentFrameID.map { ProtocolFrame.ID($0) },
        isProvisional: isProvisional,
        isPaused: false
    )
}
