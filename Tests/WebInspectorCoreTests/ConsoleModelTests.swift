import Observation
import Synchronization
import Testing
import WebInspectorTransport
@testable import WebInspectorCore

@Test
@MainActor
func consoleSessionAppendsMessagesUpdatesTargetScopedRepeatsAndClearsByTarget() throws {
    let session = ConsoleSession()
    let pageTargetID = ProtocolTarget.ID("page")
    let frameTargetID = ProtocolTarget.ID("frame")

    let pageMessageID = session.applyMessageAdded(
        ConsoleMessagePayload(
            source: .consoleAPI,
            level: .warning,
            text: "Repeated warning",
            type: .log,
            networkRequestID: NetworkRequest.ProtocolID("request-1")
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
    #expect(pageMessage.networkRequestKey == NetworkRequest.ID(targetID: pageTargetID, requestID: .init("request-1")))
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
        targetID: ProtocolTarget.ID("page")
    )

    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func consoleTargetStateKeepsStableObservableIdentity() throws {
    let session = ConsoleSession()
    let targetID = ProtocolTarget.ID("page")

    session.applyMessageAdded(
        ConsoleMessagePayload(source: .consoleAPI, level: .log, text: "first", type: .log),
        targetID: targetID
    )

    let targetState = try #require(session.targetState(for: targetID))
    let didChange = Mutex(false)

    withObservationTracking {
        _ = targetState.messages.count
    } onChange: {
        didChange.withLock { $0 = true }
    }

    session.applyMessageAdded(
        ConsoleMessagePayload(source: .consoleAPI, level: .warning, text: "second", type: .log),
        targetID: targetID
    )

    #expect(session.targetState(for: targetID) === targetState)
    #expect(targetState.messages.map(\.text) == ["first", "second"])
    #expect(targetState.warningCount == 1)
    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func consoleMessageParametersUseObservableRuntimeObjects() throws {
    let session = ConsoleSession()
    let targetID = ProtocolTarget.ID("page")
    let objectID = RuntimeRemoteObjectIdentifier("console-object")

    let messageID = session.applyMessageAdded(
        ConsoleMessagePayload(
            source: .consoleAPI,
            level: .log,
            text: "object",
            type: .log,
            parameters: [
                RuntimeRemoteObjectPayload(type: .object, description: "before", objectID: objectID),
            ]
        ),
        targetID: targetID
    )

    let message = try #require(session.message(for: messageID))
    let parameter = try #require(message.parameters.first)
    let didChange = Mutex(false)

    withObservationTracking {
        _ = parameter.payload.description
    } onChange: {
        didChange.withLock { $0 = true }
    }

    parameter.payload = RuntimeRemoteObjectPayload(type: .object, description: "after", objectID: objectID)

    #expect(parameter.remoteObjectKey == RuntimeRemoteObjectIdentifierKey(runtimeAgentTargetID: targetID, objectID: objectID))
    #expect(message.parameters.first === parameter)
    #expect(session.snapshot().messagesByID[messageID]?.parameters.first?.description == "after")
    #expect(didChange.withLock { $0 })
}

@Test
@MainActor
func consoleTargetCommitKeepsRepeatUpdatesPointedAtNewestMessage() throws {
    let session = ConsoleSession()
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")

    let oldMessageID = session.applyMessageAdded(
        ConsoleMessagePayload(source: .consoleAPI, level: .warning, text: "old", type: .log),
        targetID: oldTargetID
    )
    let newMessageID = session.applyMessageAdded(
        ConsoleMessagePayload(source: .consoleAPI, level: .warning, text: "new", type: .log),
        targetID: newTargetID
    )

    session.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: newTargetID)
    session.applyRepeatCountUpdated(count: 4, timestamp: 12, targetID: newTargetID)

    let snapshot = session.snapshot()
    let retargetedOldMessageID = ConsoleMessageIdentifier(
        targetID: newTargetID,
        ordinal: oldMessageID.ordinal
    )
    #expect(snapshot.messagesByID[retargetedOldMessageID]?.repeatCount == 1)
    #expect(snapshot.messagesByID[newMessageID]?.repeatCount == 4)
    #expect(snapshot.messagesByID[newMessageID]?.timestamp == 12)
    #expect(snapshot.warningCountByTargetID[newTargetID] == 5)
}

@Test
@MainActor
func consoleTargetCommitPreservesDisplayParametersWithoutRekeyingStaleObjectHandles() throws {
    let session = ConsoleSession()
    let oldTargetID = ProtocolTarget.ID("page-old")
    let newTargetID = ProtocolTarget.ID("page-new")
    let objectID = RuntimeRemoteObjectIdentifier("old-agent-object")

    let oldMessageID = session.applyMessageAdded(
        ConsoleMessagePayload(
            source: .consoleAPI,
            level: .log,
            text: "old object",
            type: .log,
            parameters: [
                RuntimeRemoteObjectPayload(type: .object, description: "stale", objectID: objectID),
            ]
        ),
        targetID: oldTargetID
    )

    session.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: newTargetID)

    let retargetedMessageID = ConsoleMessageIdentifier(
        targetID: newTargetID,
        ordinal: oldMessageID.ordinal
    )
    let message = try #require(session.message(for: retargetedMessageID))
    let parameter = try #require(message.parameters.first)
    #expect(parameter.payload.objectID == objectID)
    #expect(parameter.payload.description == "stale")
    #expect(parameter.remoteObjectKey == nil)
}
