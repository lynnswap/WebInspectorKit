import Foundation
import WebInspectorEngine

@MainActor
package final class DOMFrameDocumentCoordinator {
    package struct PendingSnapshot: Sendable {
        package let targetIdentifier: String
        package let snapshot: DOMGraphSnapshot

        package init(targetIdentifier: String, snapshot: DOMGraphSnapshot) {
            self.targetIdentifier = targetIdentifier
            self.snapshot = snapshot
        }
    }

    private var pendingSnapshotsByTargetIdentifier: [String: PendingSnapshot] = [:]

    package var pendingTargetIdentifiers: [String] {
        pendingSnapshotsByTargetIdentifier.keys.sorted()
    }

    package func reset() {
        pendingSnapshotsByTargetIdentifier.removeAll(keepingCapacity: false)
    }

    package func containsPendingSnapshot(targetIdentifier: String) -> Bool {
        pendingSnapshotsByTargetIdentifier[targetIdentifier] != nil
    }

    package func rememberPendingSnapshot(_ snapshot: DOMGraphSnapshot, targetIdentifier: String) {
        pendingSnapshotsByTargetIdentifier[targetIdentifier] = PendingSnapshot(
            targetIdentifier: targetIdentifier,
            snapshot: snapshot
        )
    }

    package func removePendingSnapshot(targetIdentifier: String) {
        pendingSnapshotsByTargetIdentifier.removeValue(forKey: targetIdentifier)
    }

    @discardableResult
    package func attachFrameDocumentIfPossible(
        _ root: DOMGraphNodeDescriptor,
        targetIdentifier: String,
        ownerForFrameID: (String) -> DOMNodeModel?,
        attach: (DOMNodeModel, DOMGraphNodeDescriptor) -> Void
    ) -> Bool {
        guard let frameID = root.frameID,
              let owner = ownerForFrameID(frameID) else {
            return false
        }

        var replacementRoot = root
        replacementRoot.frameID = owner.frameID ?? frameID
        attach(owner, replacementRoot)
        pendingSnapshotsByTargetIdentifier.removeValue(forKey: targetIdentifier)
        return true
    }

    @discardableResult
    package func attachPendingFrameDocumentsIfPossible(
        ownerForFrameID: (String) -> DOMNodeModel?,
        attach: (DOMNodeModel, DOMGraphNodeDescriptor) -> Void
    ) -> [String] {
        var attachedTargetIdentifiers: [String] = []
        for targetIdentifier in pendingSnapshotsByTargetIdentifier.keys.sorted() {
            guard let pendingSnapshot = pendingSnapshotsByTargetIdentifier[targetIdentifier] else {
                continue
            }
            guard attachFrameDocumentIfPossible(
                pendingSnapshot.snapshot.root,
                targetIdentifier: pendingSnapshot.targetIdentifier,
                ownerForFrameID: ownerForFrameID,
                attach: attach
            ) else {
                continue
            }
            attachedTargetIdentifiers.append(targetIdentifier)
        }
        return attachedTargetIdentifiers
    }
}
