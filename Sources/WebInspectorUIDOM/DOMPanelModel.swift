import Observation
import WebInspectorDataKit

package struct DOMPanelSelection: Equatable, Sendable {
    package let nodeID: DOMNode.ID
    package let revealPolicy: DOMRevealPolicy
    package let revision: UInt64
}

@MainActor
@Observable
package final class DOMPanelModel {
    private enum Lifecycle {
        case active
        case retiring(Task<Void, Never>?, Task<Void, Never>?)
        case retired
    }

    package let context: WebInspectorModelContext
    package let nodes: WebInspectorFetchedResultsController<DOMNode, Never>
    package private(set) var selection: DOMPanelSelection?
    package private(set) var isPickingElement = false
    package private(set) var selectionRevision: UInt64 = 0
    @ObservationIgnored private var nodeUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var pickerTask: Task<Void, Never>?
    @ObservationIgnored private var pickerGeneration: UInt64 = 0
    @ObservationIgnored private var lifecycle: Lifecycle = .active

    private init(
        context: WebInspectorModelContext,
        nodes: WebInspectorFetchedResultsController<DOMNode, Never>
    ) {
        self.context = context
        self.nodes = nodes
        startObservingNodeMembership()
    }

    package static func make(
        context: WebInspectorModelContext
    ) async throws -> DOMPanelModel {
        let nodes = try await WebInspectorFetchedResultsController<DOMNode, Never>(
            modelContext: context,
            isolation: MainActor.shared
        )
        return DOMPanelModel(context: context, nodes: nodes)
    }

    isolated deinit {
        synchronouslyCancelForOwnerDeinit()
    }

    package var selectedNodeID: DOMNode.ID? {
        liveSelection?.nodeID
    }

    package var selectedNode: DOMNode? {
        guard let selection = liveSelection else {
            return nil
        }
        return context.model(for: selection.nodeID)
    }

    package func treeUpdates() -> WebInspectorDOMTreeUpdateSequence {
        requireActive()
        return context.domTreeUpdates()
    }

    package func rebaseTree(
        _ token: WebInspectorRevisionedSnapshotRebaseToken
    ) throws -> WebInspectorRevisionedSnapshotRebase<WebInspectorDOMTreeSnapshot> {
        requireActive()
        return try context.rebaseDOMTree(token)
    }

    package func selectNode(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy
    ) {
        requireActive()
        guard let nodeID,
            nodes.snapshot.itemIDs.contains(nodeID),
            context.model(for: nodeID) != nil
        else {
            publishSelection(nil, reveal: .none)
            return
        }
        publishSelection(nodeID, reveal: reveal)
    }

    package func toggleElementPicker() {
        requireActive()
        if let pickerTask {
            pickerTask.cancel()
            return
        }
        startElementPicker()
    }

    package func cancelElementPicker() {
        pickerTask?.cancel()
    }

    package func retire() async {
        switch lifecycle {
        case .active:
            let nodeTask = nodeUpdatesTask
            let pickerTask = pickerTask
            nodeUpdatesTask = nil
            self.pickerTask = nil
            nodeTask?.cancel()
            pickerTask?.cancel()
            lifecycle = .retiring(nodeTask, pickerTask)
            await nodeTask?.value
            await pickerTask?.value
            await nodes.close()
            lifecycle = .retired
        case let .retiring(nodeTask, pickerTask):
            await nodeTask?.value
            await pickerTask?.value
            lifecycle = .retired
        case .retired:
            return
        }
    }

    package func synchronouslyCancelForOwnerDeinit() {
        nodeUpdatesTask?.cancel()
        pickerTask?.cancel()
        nodeUpdatesTask = nil
        pickerTask = nil
        if case let .retiring(nodeTask, pickerTask) = lifecycle {
            nodeTask?.cancel()
            pickerTask?.cancel()
        }
        lifecycle = .retired
    }

    private func startObservingNodeMembership() {
        let updates = nodes.updates()
        nodeUpdatesTask = Task { @MainActor [weak self] in
            do {
                for try await _ in updates {
                    self?.reconcileSelectionMembership()
                }
            } catch WebInspectorFetchedResultsControllerError.closed {
                return
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("DOM node membership updates failed: \(error)")
            }
        }
    }

    private func startElementPicker() {
        precondition(pickerTask == nil)
        precondition(pickerGeneration < UInt64.max)
        pickerGeneration += 1
        let generation = pickerGeneration
        isPickingElement = true
        WebInspectorUIDOMLog.debug(
            "DOM picker started generation=\(generation)"
        )
        let context = context
        pickerTask = Task { @MainActor [weak self] in
            let selectedID: DOMNode.ID?
            do {
                selectedID = try await context.pickDOMNodeID()
            } catch is CancellationError {
                selectedID = nil
            } catch WebInspectorElementPickerError.detached,
                WebInspectorElementPickerError.closed
            {
                selectedID = nil
            } catch {
                WebInspectorUIDOMLog.debug(
                    "DOM picker failed: \(String(describing: error))"
                )
                selectedID = nil
            }
            guard let self,
                isCurrentPickerGeneration(generation)
            else {
                return
            }
            pickerTask = nil
            isPickingElement = false
            WebInspectorUIDOMLog.debug(
                "DOM picker finished generation=\(generation) selected=\(String(describing: selectedID))"
            )
            if let selectedID {
                selectNode(selectedID, reveal: .selectAndScroll)
            }
        }
    }

    private func reconcileSelectionMembership() {
        guard let selection,
            nodes.snapshot.itemIDs.contains(selection.nodeID),
            context.model(for: selection.nodeID) != nil
        else {
            if selection != nil {
                publishSelection(nil, reveal: .none)
            }
            return
        }
    }

    private func publishSelection(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy
    ) {
        guard selection?.nodeID != nodeID
                || (nodeID != nil && reveal != .none)
        else {
            return
        }
        precondition(selectionRevision < UInt64.max)
        selectionRevision += 1
        selection = nodeID.map {
            DOMPanelSelection(
                nodeID: $0,
                revealPolicy: reveal,
                revision: selectionRevision
            )
        }
    }

    private var liveSelection: DOMPanelSelection? {
        guard let selection,
            nodes.snapshot.itemIDs.contains(selection.nodeID),
            context.model(for: selection.nodeID) != nil
        else {
            return nil
        }
        return selection
    }

    private func isCurrentPickerGeneration(_ generation: UInt64) -> Bool {
        guard case .active = lifecycle else {
            return false
        }
        return pickerGeneration == generation
    }

    private func requireActive() {
        guard case .active = lifecycle else {
            preconditionFailure("A retired DOMPanelModel cannot accept new work.")
        }
    }

    #if DEBUG
        package var isRetiredForTesting: Bool {
            if case .retired = lifecycle {
                return true
            }
            return false
        }
    #endif
}
