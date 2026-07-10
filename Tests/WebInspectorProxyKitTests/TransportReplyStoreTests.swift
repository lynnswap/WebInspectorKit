import Foundation
import Testing
@testable import WebInspectorProxyKit

@Test
func replyStoreRemovingTargetCleansWrapperIndex() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)

    store.insertTargetReply(
        pendingReply(targetID: .init("frame-old")),
        key: oldKey,
        rootWrapperID: 100
    )
    let removed = store.removeTargetReplies(for: .init("frame-old"))

    #expect(removed.count == 1)
    #expect(store.pendingTargetReplyKeys.isEmpty)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
}

@Test
func replyStoreTimeoutRemovesOriginalTargetReplyAndIndexes() {
    var store = TransportReplyStore()
    let oldKey = TransportSession.ReplyKey(targetID: .init("frame-old"), commandID: 7)

    store.insertTargetReply(
        pendingReply(targetID: .init("frame-old")),
        key: oldKey,
        rootWrapperID: 100
    )
    let removed = store.removeTargetReplyForTimeout(oldKey)

    #expect(removed?.targetID == ProtocolTarget.ID("frame-old"))
    #expect(store.pendingTargetReplyKeys.isEmpty)
    #expect(store.takeTargetReplyKey(forRootWrapperID: 100) == nil)
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
