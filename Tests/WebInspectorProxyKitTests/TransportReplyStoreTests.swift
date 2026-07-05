import Foundation
import Testing
@testable import WebInspectorProxyKit

@Test
func replyStoreRetargetsWrapperIndexWithPendingTargetReply() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)
    let newKey = TransportSession.ReplyKey(targetID: .init("frame-new"), commandID: 7)

    store.insertTargetReply(
        pendingReply(targetID: .init("frame-old")),
        key: oldKey,
        rootWrapperID: 100
    )
    store.retargetPendingReplies(from: .init("frame-old"), to: .init("frame-new"))

    #expect(store.pendingTargetReplyKeys == [newKey])
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == newKey)
    #expect(store.removeTargetReply(for: newKey) != nil)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
}

@Test
func replyStoreUsesCommandIndexForRetargetedTimeout() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)

    store.insertTargetReply(
        pendingReply(targetID: .init("frame-old")),
        key: oldKey,
        rootWrapperID: 100
    )
    store.retargetPendingReplies(from: .init("frame-old"), to: .init("frame-new"))
    let removed = store.removeTargetReplyForTimeout(oldKey)

    #expect(removed?.targetID == ProtocolTarget.ID("frame-new"))
    #expect(store.pendingTargetReplyKeys.isEmpty)
}

@Test
func replyStoreReplacingCommandCleansStaleIndexes() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)
    let newKey = TransportSession.ReplyKey(targetID: .init("frame-new"), commandID: 7)

    store.insertTargetReply(
        pendingReply(targetID: .init("frame-old")),
        key: oldKey,
        rootWrapperID: 100
    )
    store.insertTargetReply(
        pendingReply(targetID: .init("frame-new")),
        key: newKey,
        rootWrapperID: 200
    )

    #expect(store.pendingTargetReplyKeys == [newKey])
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 200) == newKey)
}

private func pendingReply(targetID: ProtocolTarget.ID) -> TransportSession.PendingReply {
    TransportSession.PendingReply(
        domain: .dom,
        method: "DOM.getDocument",
        targetID: targetID,
        promise: ReplyPromise<ProtocolCommand.Result>(),
        hasBufferedProvisionalResponse: false
    )
}
