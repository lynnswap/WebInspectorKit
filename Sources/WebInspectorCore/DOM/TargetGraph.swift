import Foundation
import Observation
import WebInspectorTransport

package struct TargetCommit: Equatable, Sendable {
    package var oldFrameID: DOMFrame.ID?
}

package struct TargetRemoval: Equatable, Sendable {
    package var frameID: DOMFrame.ID?
}

@MainActor
@Observable
package final class TargetGraph {
    private var targetsByID: [ProtocolTarget.ID: DOMTarget]
    private var framesByID: [DOMFrame.ID: DOMFrame]
    private var runtimeContexts: RuntimeContextRegistry

    package init() {
        targetsByID = [:]
        framesByID = [:]
        runtimeContexts = RuntimeContextRegistry()
    }

    package func reset() {
        targetsByID.removeAll()
        framesByID.removeAll()
        runtimeContexts = RuntimeContextRegistry()
    }

    package func containsTarget(_ targetID: ProtocolTarget.ID) -> Bool {
        targetsByID[targetID] != nil
    }

    private func target(for targetID: ProtocolTarget.ID) -> DOMTarget? {
        targetsByID[targetID]
    }

    package func targetKind(for targetID: ProtocolTarget.ID) -> ProtocolTarget.Kind? {
        targetsByID[targetID]?.kind
    }

    package func targetCapabilities(for targetID: ProtocolTarget.ID) -> ProtocolTarget.Capabilities {
        targetsByID[targetID]?.capabilities ?? []
    }

    package func targetFrameID(for targetID: ProtocolTarget.ID) -> DOMFrame.ID? {
        targetsByID[targetID]?.frameID
    }

    package func targetParentFrameID(for targetID: ProtocolTarget.ID) -> DOMFrame.ID? {
        targetsByID[targetID]?.parentFrameID
    }

    package func isTopLevelPageTarget(_ targetID: ProtocolTarget.ID) -> Bool {
        guard let target = targetsByID[targetID] else {
            return false
        }
        return target.kind == .page && target.parentFrameID == nil
    }

    package func upsertTarget(from record: ProtocolTarget.Record) {
        let target: DOMTarget
        if let existingTarget = targetsByID[record.id] {
            target = existingTarget
        } else {
            target = DOMTarget(
                id: record.id,
                kind: record.kind,
                frameID: record.frameID,
                parentFrameID: record.parentFrameID,
                capabilities: record.capabilities,
                isProvisional: record.isProvisional,
                isPaused: record.isPaused
            )
            targetsByID[record.id] = target
        }
        target.kind = record.kind
        target.frameID = record.frameID
        target.parentFrameID = record.parentFrameID
        target.capabilities = record.capabilities
        target.isProvisional = record.isProvisional
        target.isPaused = record.isPaused
    }

    package func removeTarget(_ targetID: ProtocolTarget.ID) -> TargetRemoval? {
        guard let target = targetsByID.removeValue(forKey: targetID) else {
            return nil
        }
        return TargetRemoval(frameID: target.frameID)
    }

    @discardableResult
    package func markTargetCommitted(_ targetID: ProtocolTarget.ID) -> Bool {
        guard let target = targetsByID[targetID] else {
            return false
        }
        target.isProvisional = false
        if target.kind == .frame {
            attachFrameTarget(target)
        }
        return true
    }

    package func commitTarget(oldTargetID: ProtocolTarget.ID, newTargetID: ProtocolTarget.ID) -> TargetCommit? {
        guard let oldTarget = targetsByID.removeValue(forKey: oldTargetID) else {
            return nil
        }
        let existingNewTarget = targetsByID[newTargetID]
        let frameID = existingNewTarget?.frameID ?? oldTarget.frameID
        let parentFrameID = existingNewTarget?.parentFrameID ?? oldTarget.parentFrameID
        let committedTarget: DOMTarget
        if let existingNewTarget {
            committedTarget = existingNewTarget
        } else {
            committedTarget = DOMTarget(
                id: newTargetID,
                kind: oldTarget.kind,
                frameID: frameID,
                parentFrameID: parentFrameID,
                capabilities: oldTarget.capabilities,
                isProvisional: false,
                isPaused: oldTarget.isPaused
            )
            targetsByID[newTargetID] = committedTarget
        }
        committedTarget.kind = existingNewTarget?.kind ?? oldTarget.kind
        committedTarget.frameID = frameID
        committedTarget.parentFrameID = parentFrameID
        committedTarget.capabilities = existingNewTarget?.capabilities ?? oldTarget.capabilities
        committedTarget.isProvisional = false
        committedTarget.isPaused = existingNewTarget?.isPaused ?? oldTarget.isPaused
        if let frameID {
            retargetFrame(frameID, from: oldTargetID, to: newTargetID)
        }
        return TargetCommit(oldFrameID: oldTarget.frameID)
    }

    package func targetBelongsToCurrentPage(
        _ targetID: ProtocolTarget.ID,
        currentPageTargetID: ProtocolTarget.ID?,
        mainFrameID: DOMFrame.ID?
    ) -> Bool {
        guard targetsByID[targetID] != nil else {
            return false
        }
        guard currentPageTargetID != targetID else {
            return true
        }
        guard let frameID = targetsByID[targetID]?.frameID else {
            return false
        }

        var currentFrameID: DOMFrame.ID? = frameID
        var visitedFrameIDs = Set<DOMFrame.ID>()
        while let candidateFrameID = currentFrameID,
              visitedFrameIDs.insert(candidateFrameID).inserted {
            if candidateFrameID == mainFrameID {
                return true
            }
            currentFrameID = framesByID[candidateFrameID]?.parentFrameID
        }
        return false
    }

    private func frameWithID(_ frameID: DOMFrame.ID, parentFrameID: DOMFrame.ID?) -> DOMFrame {
        let frame: DOMFrame
        if let existingFrame = framesByID[frameID] {
            frame = existingFrame
        } else {
            frame = DOMFrame(id: frameID, parentFrameID: parentFrameID)
            framesByID[frameID] = frame
        }
        frame.parentFrameID = parentFrameID
        if let parentFrameID {
            let parent = frameWithID(parentFrameID, parentFrameID: nil)
            parent.childFrameIDs.insert(frameID)
        }
        return frame
    }

    package func hasFrame(_ frameID: DOMFrame.ID) -> Bool {
        framesByID[frameID] != nil
    }

    package func frameCurrentDocumentID(_ frameID: DOMFrame.ID) -> DOMDocument.ID? {
        framesByID[frameID]?.currentDocumentID
    }

    package func setFrameCurrentDocumentID(_ documentID: DOMDocument.ID?, for frameID: DOMFrame.ID) {
        framesByID[frameID]?.currentDocumentID = documentID
    }

    package func clearFrameCurrentDocumentID(_ frameID: DOMFrame.ID, matching documentID: DOMDocument.ID) {
        if framesByID[frameID]?.currentDocumentID == documentID {
            framesByID[frameID]?.currentDocumentID = nil
        }
    }

    package func setFrameTargetID(_ targetID: ProtocolTarget.ID?, for frameID: DOMFrame.ID) {
        framesByID[frameID]?.targetID = targetID
    }

    package func frameTargetID(_ frameID: DOMFrame.ID) -> ProtocolTarget.ID? {
        framesByID[frameID]?.targetID
    }

    package func assignMainFrame(_ frameID: DOMFrame.ID, to targetID: ProtocolTarget.ID) {
        let frame = frameWithID(frameID, parentFrameID: nil)
        frame.targetID = targetID
        targetsByID[targetID]?.frameID = frameID
    }

    package func attachFrameTarget(_ targetID: ProtocolTarget.ID) {
        guard let target = targetsByID[targetID] else {
            return
        }
        attachFrameTarget(target)
    }

    private func attachFrameTarget(_ target: DOMTarget) {
        guard let frameID = target.frameID else {
            return
        }
        let frame = frameWithID(frameID, parentFrameID: target.parentFrameID)
        frame.targetID = target.id
    }

    package func attachKnownFrameTargets(mainFrameID: DOMFrame.ID?) {
        var attachedTargetIDs = Set<ProtocolTarget.ID>()
        var didAttach = true
        while didAttach {
            didAttach = false
            for target in targetsByID.values where target.kind == .frame && attachedTargetIDs.contains(target.id) == false {
                guard let parentFrameID = target.parentFrameID,
                      parentFrameID == mainFrameID || framesByID[parentFrameID] != nil else {
                    continue
                }
                attachFrameTarget(target)
                attachedTargetIDs.insert(target.id)
                didAttach = true
            }
        }
    }

    private func retargetFrame(_ frameID: DOMFrame.ID, from oldTargetID: ProtocolTarget.ID, to newTargetID: ProtocolTarget.ID) {
        let frame = frameWithID(frameID, parentFrameID: target(for: newTargetID)?.parentFrameID)
        if frame.targetID == oldTargetID || frame.targetID == nil {
            frame.targetID = newTargetID
        }
    }

    package func clearCurrentDocumentReference(
        _ documentID: DOMDocument.ID,
        targetFrameID: DOMFrame.ID?,
        targetID: ProtocolTarget.ID,
        currentPageTargetID: ProtocolTarget.ID?,
        mainFrameID: DOMFrame.ID?
    ) {
        if let frameID = targetFrameID,
           framesByID[frameID]?.currentDocumentID == documentID {
            framesByID[frameID]?.currentDocumentID = nil
        }
        if currentPageTargetID == targetID,
           let mainFrameID,
           framesByID[mainFrameID]?.currentDocumentID == documentID {
            framesByID[mainFrameID]?.currentDocumentID = nil
        }
    }

    package func removeExecutionContexts(targetID: ProtocolTarget.ID) {
        runtimeContexts.removeContexts(targetID: targetID)
    }

    package func removeExecutionContexts(runtimeAgentTargetID: ProtocolTarget.ID) {
        runtimeContexts.clear(runtimeAgentTargetID: runtimeAgentTargetID)
    }

    package func removeExecutionContext(_ contextKey: RuntimeExecutionContextKey) {
        runtimeContexts.remove(contextKey)
    }

    package func retargetExecutionContexts(from oldTargetID: ProtocolTarget.ID, to newTargetID: ProtocolTarget.ID) {
        runtimeContexts.retarget(oldTargetID: oldTargetID, newTargetID: newTargetID)
    }

    package func recordExecutionContext(_ context: RuntimeExecutionContextRecord) {
        runtimeContexts.record(context)
    }

    package func targetSnapshots(
        currentDocumentID: (ProtocolTarget.ID) -> DOMDocument.ID?
    ) -> [ProtocolTarget.ID: DOMTarget.Snapshot] {
        targetsByID.mapValues {
            DOMTarget.Snapshot(
                id: $0.id,
                kind: $0.kind,
                frameID: $0.frameID,
                parentFrameID: $0.parentFrameID,
                capabilities: $0.capabilities,
                isProvisional: $0.isProvisional,
                isPaused: $0.isPaused,
                currentDocumentID: currentDocumentID($0.id)
            )
        }
    }

    package func frameSnapshots() -> [DOMFrame.ID: DOMFrame.Snapshot] {
        framesByID.mapValues {
            DOMFrame.Snapshot(
                id: $0.id,
                parentFrameID: $0.parentFrameID,
                childFrameIDs: $0.childFrameIDs,
                targetID: $0.targetID,
                currentDocumentID: $0.currentDocumentID
            )
        }
    }

    package func executionContextSnapshots() -> [RuntimeExecutionContextKey: RuntimeExecutionContextRecord] {
        runtimeContexts.contextsByKey
    }
}
