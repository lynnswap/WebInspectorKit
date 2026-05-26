import Observation
import Synchronization
import Testing
@testable import WebInspectorCore

@Test
@MainActor
func consoleSessionAppendsMessagesUpdatesTargetScopedRepeatsAndClearsByTarget() throws {
    let session = ConsoleSession()
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")

    let pageMessageID = session.applyMessageAdded(
        ConsoleMessagePayload(
            source: .consoleAPI,
            level: .warning,
            text: "Repeated warning",
            type: .log,
            networkRequestID: NetworkRequestIdentifier("request-1")
        ),
        targetID: pageTargetID
    )
    _ = session.applyMessageAdded(
        ConsoleMessagePayload(source: .javascript, level: .error, text: "Frame error", type: .log),
        targetID: frameTargetID
    )
    session.applyRepeatCountUpdated(count: 3, timestamp: 42, targetID: pageTargetID)

    var snapshot = session.snapshot()
    let pageMessage = try #require(snapshot.messagesByID[pageMessageID])
    #expect(pageMessage.repeatCount == 3)
    #expect(pageMessage.timestamp == 42)
    #expect(pageMessage.networkRequestKey == NetworkRequestIdentifierKey(targetID: pageTargetID, requestID: .init("request-1")))
    #expect(snapshot.warningCount == 3)
    #expect(snapshot.errorCount == 1)
    #expect(snapshot.warningCountByTargetID[pageTargetID] == 3)
    #expect(snapshot.errorCountByTargetID[frameTargetID] == 1)

    session.applyMessagesCleared(reason: .frontend, targetID: pageTargetID)
    snapshot = session.snapshot()
    #expect(snapshot.orderedMessageIDs.map(\.targetID) == [frameTargetID])
    #expect(snapshot.lastClearReasonByTargetID[pageTargetID] == .frontend)
    #expect(snapshot.warningCount == 0)
    #expect(snapshot.errorCount == 1)
}

@Test
@MainActor
func consoleSessionMessagesInvalidatesObserversWhenNormalMessageIsAdded() {
    let session = ConsoleSession()
    let didChange = Mutex(false)

    withObservationTracking {
        _ = session.messages.count
    } onChange: {
        didChange.withLock { $0 = true }
    }

    session.applyMessageAdded(
        ConsoleMessagePayload(source: .consoleAPI, level: .log, text: "hello", type: .log),
        targetID: ProtocolTargetIdentifier("page")
    )

    #expect(didChange.withLock { $0 })
}
