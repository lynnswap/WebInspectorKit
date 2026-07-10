import Foundation
import Testing
@testable import WebInspectorProxyKit

@Test
func replyStoreRemovingTargetCleansWrapperIndex() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)
    let pending = capabilityPendingReply(targetID: .init("frame-old"), operationID: 11)

    store.insertTargetReply(
        pending,
        key: oldKey,
        rootWrapperID: 100
    )
    let removed = store.removeTargetReplies(for: .init("frame-old"))

    #expect(removed.count == 1)
    #expect(removed.first?.purpose == pending.purpose)
    #expect(store.pendingTargetReplyKeys.isEmpty)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
}

@Test
func replyStoreTimeoutRemovesOriginalTargetReplyAndIndexes() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)
    let pending = capabilityPendingReply(targetID: .init("frame-old"), operationID: 12)

    store.insertTargetReply(
        pending,
        key: oldKey,
        rootWrapperID: 100
    )
    let removed = store.removeTargetReplyForTimeout(oldKey)

    #expect(removed?.targetID == ProtocolTarget.ID("frame-old"))
    #expect(removed?.purpose == pending.purpose)
    #expect(store.pendingTargetReplyKeys.isEmpty)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
}

@Test
func replyStoreRetargetedTimeoutPreservesPurpose() {
    var store = TransportReplyStore()
    let originalKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)
    let currentKey = TransportSession.ReplyKey(targetID: .init("frame-new"), commandID: 7)
    let pending = capabilityPendingReply(targetID: .init("frame-new"), operationID: 13)

    store.insertTargetReply(
        pending,
        key: currentKey,
        rootWrapperID: 100
    )
    let removed = store.removeTargetReplyForTimeout(originalKey)

    #expect(removed?.targetID == ProtocolTarget.ID("frame-new"))
    #expect(removed?.purpose == pending.purpose)
    #expect(store.pendingTargetReplyKeys.isEmpty)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
}

@Test
func replyStoreRemovingThenReusingCommandCleansStaleIndexes() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)
    let newKey = TransportSession.ReplyKey(targetID: .init("frame-new"), commandID: 7)

    store.insertTargetReply(
        clientPendingReply(targetID: .init("frame-old")),
        key: oldKey,
        rootWrapperID: 100
    )
    let removed = store.removeTargetReply(for: oldKey)
    store.insertTargetReply(
        clientPendingReply(targetID: .init("frame-new")),
        key: newKey,
        rootWrapperID: 200
    )

    #expect(removed?.purpose == .client)
    #expect(store.pendingTargetReplyKeys == [newKey])
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 200) == newKey)
}

@Test
func replyStoreRootRemovalPreservesClientPurpose() {
    var store = TransportReplyStore()
    store.insertRootReply(
        clientPendingReply(targetID: nil),
        commandID: 42
    )

    let removed = store.removePendingReply(.root(42))

    #expect(removed?.purpose == .client)
    #expect(store.pendingRootReplyIDs.isEmpty)
}

private func clientPendingReply(
    targetID: ProtocolTarget.ID?
) -> TransportSession.PendingReply {
    TransportSession.PendingReply.client(
        domain: .dom,
        method: "DOM.getDocument",
        targetID: targetID,
        promise: ReplyPromise<ProtocolCommand.Result>()
    )
}

private func capabilityPendingReply(
    targetID: ProtocolTarget.ID,
    operationID: UInt64
) -> TransportSession.PendingReply {
    TransportSession.PendingReply.capability(
        domain: .network,
        method: "Network.enable",
        targetID: targetID,
        promise: ReplyPromise<ProtocolCommand.Result>(),
        key: ConnectionCapabilityKey(
            route: RoutingTargetID(targetID.rawValue),
            targetID: WebInspectorTarget.ID(targetID.rawValue),
            domain: .network
        ),
        generation: WebInspectorPage.Generation(rawValue: 3),
        operationID: operationID
    )
}
