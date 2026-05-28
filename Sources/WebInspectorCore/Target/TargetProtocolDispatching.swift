import Foundation
import WebInspectorTransport

package struct TargetProtocolCommitResolution: Equatable, Sendable {
    package var oldTargetID: ProtocolTargetIdentifier?
    package var newTargetID: ProtocolTargetIdentifier
    package var consumedOldTargetID: ProtocolTargetIdentifier?
}

package struct TargetProtocolEventSnapshot: Sendable {
    package var currentPageTargetID: ProtocolTargetIdentifier?
    package var mainFrameID: DOMFrameIdentifier?
    package var targetsByID: [ProtocolTargetIdentifier: ProtocolTargetSnapshot]

    package init(
        currentPageTargetID: ProtocolTargetIdentifier?,
        mainFrameID: DOMFrameIdentifier?,
        targetsByID: [ProtocolTargetIdentifier: ProtocolTargetSnapshot]
    ) {
        self.currentPageTargetID = currentPageTargetID
        self.mainFrameID = mainFrameID
        self.targetsByID = targetsByID
    }
}

package struct TargetProtocolEventResult: Sendable {
    package var destroyedTargetID: ProtocolTargetIdentifier?
    package var targetCommit: TargetProtocolCommitResolution?
    package var createdTarget: ProtocolTargetRecord?
}

@MainActor
package protocol TargetProtocolEventHandler: AnyObject {
    func targetProtocolSnapshot() -> TargetProtocolEventSnapshot
    func targetProtocolDidCreate(_ record: ProtocolTargetRecord, makeCurrentMainPage: Bool)
    func targetProtocolDidDestroy(_ targetID: ProtocolTargetIdentifier)
    func targetProtocolDidCommit(_ resolution: TargetProtocolCommitResolution, snapshotBeforeCommit: TargetProtocolEventSnapshot)
}

package struct TargetProtocolEventDispatcher {
    package init() {}

    @MainActor
    @discardableResult
    package func dispatch(
        _ event: ProtocolEventEnvelope,
        to handler: any TargetProtocolEventHandler
    ) throws -> TargetProtocolEventResult {
        let snapshotBeforeEvent = handler.targetProtocolSnapshot()
        let destroyedTargetID = try targetDestroyedID(from: event)
        let targetCommit = try targetCommitResolution(from: event, snapshot: snapshotBeforeEvent)
        let createdTarget = try apply(event, to: handler, snapshotBeforeEvent: snapshotBeforeEvent, targetCommit: targetCommit)
        return TargetProtocolEventResult(
            destroyedTargetID: destroyedTargetID,
            targetCommit: targetCommit,
            createdTarget: createdTarget
        )
    }

    @MainActor
    @discardableResult
    private func apply(
        _ event: ProtocolEventEnvelope,
        to handler: any TargetProtocolEventHandler,
        snapshotBeforeEvent: TargetProtocolEventSnapshot,
        targetCommit: TargetProtocolCommitResolution?
    ) throws -> ProtocolTargetRecord? {
        switch event.method {
        case "Target.targetCreated":
            let params = try TransportMessageParser.decode(TargetCreatedParams.self, from: event.paramsData)
            let record = params.targetInfo.record(currentMainFrameID: snapshotBeforeEvent.mainFrameID)
            let makeCurrentMainPage = snapshotBeforeEvent.currentPageTargetID == nil
                && record.kind == .page
                && record.parentFrameID == nil
                && !record.isProvisional
            handler.targetProtocolDidCreate(record, makeCurrentMainPage: makeCurrentMainPage)
            return record
        case "Target.targetDestroyed":
            let params = try TransportMessageParser.decode(TargetDestroyedParams.self, from: event.paramsData)
            handler.targetProtocolDidDestroy(params.targetId)
            return nil
        case "Target.didCommitProvisionalTarget":
            guard let targetCommit else {
                return nil
            }
            handler.targetProtocolDidCommit(targetCommit, snapshotBeforeCommit: snapshotBeforeEvent)
            return nil
        default:
            return nil
        }
    }

    package func targetCommitResolution(
        from event: ProtocolEventEnvelope,
        snapshot: TargetProtocolEventSnapshot
    ) throws -> TargetProtocolCommitResolution? {
        guard event.method == "Target.didCommitProvisionalTarget" else {
            return nil
        }
        let params = try TransportMessageParser.decode(TargetCommittedParams.self, from: event.paramsData)
        let oldTargetID = params.oldTargetId ?? inferredOldTargetIDForOldlessCommit(params, snapshot: snapshot)
        return TargetProtocolCommitResolution(
            oldTargetID: oldTargetID,
            newTargetID: params.newTargetId,
            consumedOldTargetID: oldTargetID.flatMap {
                targetCommitConsumesOldTarget(oldTargetID: $0, newTargetID: params.newTargetId, snapshot: snapshot) ? $0 : nil
            }
        )
    }

    private func targetDestroyedID(from event: ProtocolEventEnvelope) throws -> ProtocolTargetIdentifier? {
        guard event.method == "Target.targetDestroyed" else {
            return nil
        }
        let params = try TransportMessageParser.decode(TargetDestroyedParams.self, from: event.paramsData)
        return params.targetId
    }

    private func inferredOldTargetIDForOldlessCommit(
        _ params: TargetCommittedParams,
        snapshot: TargetProtocolEventSnapshot
    ) -> ProtocolTargetIdentifier? {
        guard params.oldTargetId == nil else {
            return nil
        }

        if let newTarget = snapshot.targetsByID[params.newTargetId],
           newTarget.isProvisional,
           newTarget.kind == .page,
           newTarget.parentFrameID == nil,
           let currentPageTargetID = snapshot.currentPageTargetID,
           currentPageTargetID != params.newTargetId {
            return currentPageTargetID
        }

        guard snapshot.targetsByID[params.newTargetId] == nil else {
            return nil
        }

        let provisionalTargetIDs = snapshot.targetsByID
            .filter { $0.value.isProvisional }
            .map(\.key)
        return provisionalTargetIDs.count == 1 ? provisionalTargetIDs[0] : nil
    }

    private func targetCommitConsumesOldTarget(
        oldTargetID: ProtocolTargetIdentifier,
        newTargetID: ProtocolTargetIdentifier,
        snapshot: TargetProtocolEventSnapshot
    ) -> Bool {
        guard oldTargetID != newTargetID else {
            return false
        }
        if snapshot.currentPageTargetID == oldTargetID,
           let newTarget = snapshot.targetsByID[newTargetID],
           (newTarget.kind != .page || newTarget.parentFrameID != nil) {
            return false
        }
        return true
    }
}

extension DOMSessionSnapshot {
    package var targetProtocolEventSnapshot: TargetProtocolEventSnapshot {
        TargetProtocolEventSnapshot(
            currentPageTargetID: currentPageTargetID,
            mainFrameID: mainFrameID,
            targetsByID: targetsByID
        )
    }
}

extension DOMSession: TargetProtocolEventHandler {
    package func targetProtocolSnapshot() -> TargetProtocolEventSnapshot {
        snapshot().targetProtocolEventSnapshot
    }

    package func targetProtocolDidCreate(_ record: ProtocolTargetRecord, makeCurrentMainPage: Bool) {
        applyTargetCreated(record, makeCurrentMainPage: makeCurrentMainPage)
    }

    package func targetProtocolDidDestroy(_ targetID: ProtocolTargetIdentifier) {
        applyTargetDestroyed(targetID)
    }

    package func targetProtocolDidCommit(
        _ resolution: TargetProtocolCommitResolution,
        snapshotBeforeCommit: TargetProtocolEventSnapshot
    ) {
        if let oldTargetID = resolution.consumedOldTargetID {
            applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: resolution.newTargetID)
        } else {
            applyTargetCommitted(targetID: resolution.newTargetID)
        }

        let snapshot = snapshot()
        if snapshotBeforeCommit.currentPageTargetID == nil,
           let target = snapshot.targetsByID[resolution.newTargetID],
           target.kind == .page,
           target.parentFrameID == nil {
            promoteTargetToCurrentPage(resolution.newTargetID)
        }
    }
}

@MainActor
package final class TargetProtocolDomainEventDispatcher: ProtocolDomainEventDispatcher {
    private weak var dom: DOMSession?
    private let targetEventApplied: @MainActor (ProtocolEventEnvelope, TargetProtocolEventResult) async -> Void

    package init(
        dom: DOMSession,
        targetEventApplied: @escaping @MainActor (ProtocolEventEnvelope, TargetProtocolEventResult) async -> Void
    ) {
        self.dom = dom
        self.targetEventApplied = targetEventApplied
    }

    package var domain: ProtocolDomain { .target }

    package func dispatch(_ event: ProtocolEventEnvelope) async throws {
        guard let dom else {
            return
        }
        let result = try dom.applyTargetProtocolEvent(event)
        await targetEventApplied(event, result)
    }
}

private struct TargetCreatedParams: Decodable {
    var targetInfo: TargetInfoPayload
}

private struct TargetInfoPayload: Decodable {
    var targetId: ProtocolTargetIdentifier
    var type: String
    var frameId: DOMFrameIdentifier?
    var parentFrameId: DOMFrameIdentifier?
    var domains: [String]?
    var isProvisional: Bool?
    var isPaused: Bool?

    func record(currentMainFrameID: DOMFrameIdentifier?) -> ProtocolTargetRecord {
        let kind = targetKind(currentMainFrameID: currentMainFrameID)
        return ProtocolTargetRecord(
            id: targetId,
            kind: kind,
            frameID: frameId,
            parentFrameID: parentFrameId,
            capabilities: capabilities(for: kind),
            isProvisional: isProvisional ?? false,
            isPaused: isPaused ?? false
        )
    }

    private func capabilities(for kind: ProtocolTargetKind) -> ProtocolTargetCapabilities {
        ProtocolTargetCapabilities.resolved(for: kind, domainNames: domains)
    }

    private func targetKind(currentMainFrameID: DOMFrameIdentifier?) -> ProtocolTargetKind {
        let protocolKind = ProtocolTargetKind(protocolType: type)
        guard protocolKind == .page else {
            return protocolKind
        }
        if parentFrameId != nil {
            return .frame
        }
        if let currentMainFrameID,
           let frameId,
           frameId != currentMainFrameID {
            return .frame
        }
        if currentMainFrameID == nil,
           isProvisional == true {
            return .frame
        }
        return .page
    }
}

private struct TargetDestroyedParams: Decodable {
    var targetId: ProtocolTargetIdentifier
}

private struct TargetCommittedParams: Decodable {
    var oldTargetId: ProtocolTargetIdentifier?
    var newTargetId: ProtocolTargetIdentifier
}
