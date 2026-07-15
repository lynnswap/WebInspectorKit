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
    package let context: WebInspectorModelContext
    package let nodes: WebInspectorFetchedResultsController<DOMNode>
    package private(set) var selection: DOMPanelSelection?
    package private(set) var elementPickerState: WebInspectorElementPickerState = .idle
    package private(set) var selectionRevision: UInt64 = 0

    @ObservationIgnored private var nodeUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var pickerStateTask: Task<Void, Never>?
    @ObservationIgnored private var pickerTask: Task<Void, Never>?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPickerSelectionID: DOMNode.ID?
    @ObservationIgnored private var isActive = true

    private init(
        context: WebInspectorModelContext,
        nodes: WebInspectorFetchedResultsController<DOMNode>
    ) {
        self.context = context
        self.nodes = nodes
        startObservingNodeMembership()
        startObservingPickerState()
    }

    package static func make(
        context: WebInspectorModelContext
    ) async throws -> DOMPanelModel {
        let nodes = WebInspectorFetchedResultsController<DOMNode>(
            modelContext: context
        )
        do {
            try await nodes.performFetch()
        } catch {
            await nodes.close()
            throw error
        }
        return DOMPanelModel(context: context, nodes: nodes)
    }

    isolated deinit {
        synchronouslyCancelForOwnerDeinit()
        nodes.synchronouslyInvalidateRegistration()
    }

    package var isPickingElement: Bool {
        switch elementPickerState {
        case .idle, .unavailable:
            false
        case .enabling, .active, .resolvingSelection, .disabling:
            true
        }
    }

    package var selectedNodeID: DOMNode.ID? {
        liveSelection?.nodeID
    }

    package var selectedNode: DOMNode? {
        liveSelection.flatMap { context.model(for: $0.nodeID) }
    }

    package func selectNode(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy
    ) {
        guard isActive else { return }
        pendingPickerSelectionID = nil
        guard let nodeID,
              nodeIDs.contains(nodeID),
              context.model(for: nodeID) != nil else {
            publishSelection(nil, reveal: .none)
            return
        }
        publishSelection(nodeID, reveal: reveal)
    }

    package func toggleElementPicker() {
        guard isActive else { return }
        switch elementPickerState {
        case .idle:
            startElementPicker()
        case .unavailable:
            Task { [dom = context.container.dom] in
                await dom.retryElementPicker()
            }
        case .enabling, .active, .resolvingSelection, .disabling:
            cancelElementPicker()
        }
    }

    package func cancelElementPicker() {
        guard isActive else { return }
        pendingPickerSelectionID = nil
        pickerTask?.cancel()
        Task { [dom = context.container.dom] in
            await dom.cancelElementPicker()
        }
    }

    package func retire() async {
        if let retirementTask {
            await retirementTask.value
            return
        }
        guard isActive else { return }
        isActive = false
        pendingPickerSelectionID = nil
        let nodeUpdatesTask = nodeUpdatesTask
        let pickerStateTask = pickerStateTask
        let pickerTask = pickerTask
        self.nodeUpdatesTask = nil
        self.pickerStateTask = nil
        self.pickerTask = nil
        nodeUpdatesTask?.cancel()
        pickerStateTask?.cancel()
        pickerTask?.cancel()
        let nodes = nodes
        let dom = context.container.dom
        let task = Task { @MainActor in
            await dom.cancelElementPicker()
            await nodeUpdatesTask?.value
            await pickerStateTask?.value
            await pickerTask?.value
            await nodes.close()
        }
        retirementTask = task
        await task.value
        retirementTask = nil
    }

    package func synchronouslyCancelForOwnerDeinit() {
        isActive = false
        pendingPickerSelectionID = nil
        nodeUpdatesTask?.cancel()
        pickerStateTask?.cancel()
        pickerTask?.cancel()
        retirementTask?.cancel()
        nodeUpdatesTask = nil
        pickerStateTask = nil
        pickerTask = nil
    }

    private func startObservingNodeMembership() {
        let updates = nodes.updates
        nodeUpdatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard Task.isCancelled == false else { return }
                self?.reconcileSelectionMembership()
            }
        }
    }

    private func startObservingPickerState() {
        let states = context.container.dom.elementPickerStateUpdates
        pickerStateTask = Task { @MainActor [weak self] in
            for await state in states {
                guard Task.isCancelled == false else { return }
                self?.elementPickerState = state
            }
        }
    }

    private func startElementPicker() {
        guard pickerTask == nil else { return }
        pendingPickerSelectionID = nil
        let dom = context.container.dom
        pickerTask = Task { @MainActor [weak self, dom] in
            defer { self?.pickerTask = nil }
            do {
                let selectedID = try await dom.pickElement()
                guard Task.isCancelled == false else { return }
                self?.receivePickerSelection(selectedID)
            } catch is CancellationError {
                return
            } catch {
                WebInspectorUIDOMLog.error(
                    "DOM picker failed: \(String(describing: error))"
                )
            }
        }
    }

    private func reconcileSelectionMembership() {
        if let selection,
           !hasPublishedNode(selection.nodeID) {
            publishSelection(nil, reveal: .none)
        }
        publishPendingPickerSelectionIfAvailable()
    }

    private func receivePickerSelection(_ nodeID: DOMNode.ID) {
        guard isActive else { return }
        pendingPickerSelectionID = nodeID
        publishPendingPickerSelectionIfAvailable()
    }

    private func publishPendingPickerSelectionIfAvailable() {
        guard let nodeID = pendingPickerSelectionID,
              hasPublishedNode(nodeID) else { return }
        pendingPickerSelectionID = nil
        publishSelection(nodeID, reveal: .selectAndScroll)
    }

    private func hasPublishedNode(_ nodeID: DOMNode.ID) -> Bool {
        nodeIDs.contains(nodeID) && context.model(for: nodeID) != nil
    }

    private func publishSelection(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy
    ) {
        guard selection?.nodeID != nodeID
                || (nodeID != nil && reveal != .none) else {
            return
        }
        selectionRevision &+= 1
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
              nodeIDs.contains(selection.nodeID),
              context.model(for: selection.nodeID) != nil else {
            return nil
        }
        return selection
    }

    private var nodeIDs: [DOMNode.ID] {
        nodes.snapshot?.itemIDs ?? []
    }

    #if DEBUG
    package var isRetiredForTesting: Bool { isActive == false }
    package var pendingPickerSelectionIDForTesting: DOMNode.ID? {
        pendingPickerSelectionID
    }

    package func receivePickerSelectionForTesting(_ nodeID: DOMNode.ID) {
        receivePickerSelection(nodeID)
    }
    #endif
}
