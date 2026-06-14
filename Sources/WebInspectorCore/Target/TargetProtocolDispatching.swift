import Foundation
import WebInspectorTransport

package struct TargetProtocolCommitResolution: Equatable, Sendable {
    package var oldTargetID: ProtocolTarget.ID?
    package var newTargetID: ProtocolTarget.ID
    package var consumedOldTargetID: ProtocolTarget.ID?
}

package struct TargetProtocolEventSnapshot: Sendable {
    package var currentPageTargetID: ProtocolTarget.ID?
    package var mainFrameID: DOMFrameIdentifier?
    package var targetsByID: [ProtocolTarget.ID: ProtocolTargetSnapshot]

    package init(
        currentPageTargetID: ProtocolTarget.ID?,
        mainFrameID: DOMFrameIdentifier?,
        targetsByID: [ProtocolTarget.ID: ProtocolTargetSnapshot]
    ) {
        self.currentPageTargetID = currentPageTargetID
        self.mainFrameID = mainFrameID
        self.targetsByID = targetsByID
    }
}

package struct TargetProtocolEventResult: Sendable {
    package var destroyedTargetID: ProtocolTarget.ID?
    package var targetCommit: TargetProtocolCommitResolution?
    package var createdTarget: ProtocolTarget.Record?
}

@MainActor
package protocol TargetProtocolEventHandler: AnyObject {
    func targetProtocolSnapshot() -> TargetProtocolEventSnapshot
    func targetProtocolDidCreate(_ record: ProtocolTarget.Record, makeCurrentMainPage: Bool)
    func targetProtocolDidDestroy(_ targetID: ProtocolTarget.ID)
    func targetProtocolDidCommit(_ resolution: TargetProtocolCommitResolution, snapshotBeforeCommit: TargetProtocolEventSnapshot)
}

package struct TargetProtocolEventDispatcher {
    package init() {}

    @MainActor
    @discardableResult
    package func dispatch(
        _ event: ProtocolEvent,
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
        _ event: ProtocolEvent,
        to handler: any TargetProtocolEventHandler,
        snapshotBeforeEvent: TargetProtocolEventSnapshot,
        targetCommit: TargetProtocolCommitResolution?
    ) throws -> ProtocolTarget.Record? {
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
        from event: ProtocolEvent,
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

    private func targetDestroyedID(from event: ProtocolEvent) throws -> ProtocolTarget.ID? {
        guard event.method == "Target.targetDestroyed" else {
            return nil
        }
        let params = try TransportMessageParser.decode(TargetDestroyedParams.self, from: event.paramsData)
        return params.targetId
    }

    private func inferredOldTargetIDForOldlessCommit(
        _ params: TargetCommittedParams,
        snapshot: TargetProtocolEventSnapshot
    ) -> ProtocolTarget.ID? {
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
        oldTargetID: ProtocolTarget.ID,
        newTargetID: ProtocolTarget.ID,
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

    package func targetProtocolDidCreate(_ record: ProtocolTarget.Record, makeCurrentMainPage: Bool) {
        applyTargetCreated(record, makeCurrentMainPage: makeCurrentMainPage)
    }

    package func targetProtocolDidDestroy(_ targetID: ProtocolTarget.ID) {
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
    private let targetEventApplied: @MainActor (ProtocolEvent, TargetProtocolEventResult) async -> Void

    package init(
        dom: DOMSession,
        targetEventApplied: @escaping @MainActor (ProtocolEvent, TargetProtocolEventResult) async -> Void
    ) {
        self.dom = dom
        self.targetEventApplied = targetEventApplied
    }

    package var domain: ProtocolDomain { .target }

    package func dispatch(_ event: ProtocolEvent) async throws {
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
    var targetId: ProtocolTarget.ID
    var type: String
    var frameId: DOMFrameIdentifier?
    var parentFrameId: DOMFrameIdentifier?
    var domains: [String]?
    var isProvisional: Bool?
    var isPaused: Bool?

    func record(currentMainFrameID: DOMFrameIdentifier?) -> ProtocolTarget.Record {
        let kind = targetKind(currentMainFrameID: currentMainFrameID)
        return ProtocolTarget.Record(
            id: targetId,
            kind: kind,
            frameID: frameId,
            parentFrameID: parentFrameId,
            capabilities: capabilities(for: kind),
            isProvisional: isProvisional ?? false,
            isPaused: isPaused ?? false
        )
    }

    private func capabilities(for kind: ProtocolTarget.Kind) -> ProtocolTarget.Capabilities {
        ProtocolTarget.Capabilities.resolved(for: kind, domainNames: domains)
    }

    private func targetKind(currentMainFrameID: DOMFrameIdentifier?) -> ProtocolTarget.Kind {
        let protocolKind = ProtocolTarget.Kind(protocolType: type)
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
    var targetId: ProtocolTarget.ID
}

private struct TargetCommittedParams: Decodable {
    var oldTargetId: ProtocolTarget.ID?
    var newTargetId: ProtocolTarget.ID
}
