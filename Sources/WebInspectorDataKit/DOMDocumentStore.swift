import Foundation
import WebInspectorProxyKit

/// The DOM tree of one attachment: its node models, the tree controllers that
/// show them, and the `DOM` events that change the tree's structure.
///
/// The store changes models and notifies tree controllers. What an event
/// needs from the connection, such as loading a frame document or resolving a
/// pending inspect, is reported as an ``EventOutcome`` for the context to do.
@MainActor
final class DOMDocumentStore {
    /// What the context still has to do after a structural event.
    enum EventOutcome {
        /// The event changed known nodes and needs nothing else.
        case applied

        /// The event added node models, so a node that an inspect is waiting
        /// for may exist now.
        case materializedNodes

        /// The event names a node that is not in the index. It may belong to
        /// a frame document that has not been loaded.
        case missingNode(DOMNode.ID, reason: String)

        /// The event is about a subtree outside the connected tree.
        case ignoredGap
    }

    let nodes = DOMNodeIndex()
    let trees = DOMTreeStateRegistry()

    /// Called when an attribute or character data of a node changed, before
    /// tree controllers are notified. The styles of that node may be stale.
    var styleInputsDidChange: ((DOMNode.ID) -> Void)?

    /// Applies an event that changes the structure or the attributes of the
    /// tree. Other `DOM` events belong to the context.
    func apply(_ event: DOM.Event) -> EventOutcome {
        switch event {
        case let .setChildNodes(parent, nodes):
            return applySetChildNodes(parent: parent, nodes: nodes)
        case let .childNodeInserted(parent, previous, node):
            return applyChildNodeInserted(parent: parent, previous: previous, node: node)
        case let .childNodeRemoved(parent, node):
            return applyChildNodeRemoved(parent: parent, node: node)
        case let .childNodeCountUpdated(id, count):
            guard let node = nodes[DOMNode.ID(id)] else {
                return .missingNode(DOMNode.ID(id), reason: "DOM.childNodeCountUpdated")
            }
            node.updateChildNodeCount(count)
            trees.childCountChanged(node: node)
            return .applied
        case let .attributeModified(id, name, value):
            guard let node = nodes[DOMNode.ID(id)] else {
                return .missingNode(DOMNode.ID(id), reason: "DOM.attributeModified")
            }
            node.setAttribute(name: name, value: value)
            styleInputsDidChange?(node.id)
            trees.nodeChanged(node)
            return .applied
        case let .attributeRemoved(id, name):
            guard let node = nodes[DOMNode.ID(id)] else {
                return .missingNode(DOMNode.ID(id), reason: "DOM.attributeRemoved")
            }
            node.removeAttribute(name: name)
            styleInputsDidChange?(node.id)
            trees.nodeChanged(node)
            return .applied
        case let .characterDataModified(id, value):
            guard let node = nodes[DOMNode.ID(id)] else {
                return .missingNode(DOMNode.ID(id), reason: "DOM.characterDataModified")
            }
            node.setNodeValue(value)
            styleInputsDidChange?(node.id)
            trees.nodeChanged(node)
            return .applied
        case .detachedRoot:
            // Detached roots need a registry and a selection policy outside
            // the single connected tree. A pending inspect has its own
            // lifecycle log.
            return .ignoredGap
        case let .shadowRootPushed(host, root):
            return applyShadowRootPushed(host: host, root: root)
        case let .shadowRootPopped(host, root):
            return applyShadowRootPopped(host: host, root: root)
        case let .pseudoElementAdded(parent, element):
            return applyPseudoElementAdded(parent: parent, element: element)
        case let .pseudoElementRemoved(parent, element):
            return applyPseudoElementRemoved(parent: parent, element: element)
        case .documentUpdated,
             .inlineStyleInvalidated,
             .inspect,
             .willDestroyDOMNode,
             .unknown:
            return .applied
        }
    }

    private func applySetChildNodes(
        parent: DOM.Node.ID,
        nodes payloads: [DOM.Node]
    ) -> EventOutcome {
        guard let parentNode = nodes[DOMNode.ID(parent)] else {
            return .missingNode(DOMNode.ID(parent), reason: "DOM.setChildNodes")
        }
        let previousChildren: [DOMNode]
        if case let .loaded(children) = parentNode.children {
            previousChildren = children
        } else {
            previousChildren = []
        }
        let (newChildren, newSubtreeIDs) = nodes.materialize(payloads)
        let newChildIDs = Set(newChildren.map(\.id))
        for previousChild in previousChildren where newChildIDs.contains(previousChild.id) == false {
            nodes.removeSubtree(previousChild, preserving: newSubtreeIDs)
        }
        parentNode.setChildren(newChildren)
        trees.childrenReplaced(parent: parentNode)
        return .materializedNodes
    }

    private func applyChildNodeInserted(
        parent: DOM.Node.ID,
        previous: DOM.Node.ID?,
        node: DOM.Node
    ) -> EventOutcome {
        guard let parentNode = nodes[DOMNode.ID(parent)] else {
            return .missingNode(DOMNode.ID(parent), reason: "DOM.childNodeInserted")
        }

        var children: [DOMNode]
        switch parentNode.children {
        case let .unrequested(count) where count > 0:
            parentNode.updateChildNodeCount(parentNode.childNodeCount + 1)
            trees.childCountChanged(node: parentNode)
            return .applied
        case .unrequested:
            children = []
        case let .loaded(loadedChildren):
            children = loadedChildren
        }
        let inserted = nodes.materialize(node).node
        if let previous, let index = children.firstIndex(where: { $0.id == DOMNode.ID(previous) }) {
            children.insert(inserted, at: children.index(after: index))
        } else {
            children.insert(inserted, at: 0)
        }
        parentNode.setChildren(children)
        trees.childInserted(
            parent: parentNode,
            node: inserted,
            previousSiblingID: previous.map(DOMNode.ID.init)
        )
        return .materializedNodes
    }

    private func applyChildNodeRemoved(
        parent: DOM.Node.ID,
        node: DOM.Node.ID
    ) -> EventOutcome {
        guard let parentNode = nodes[DOMNode.ID(parent)] else {
            return .missingNode(DOMNode.ID(parent), reason: "DOM.childNodeRemoved")
        }

        let removedID = DOMNode.ID(node)
        guard let removedNode = nodes[removedID] else {
            return .missingNode(removedID, reason: "DOM.childNodeRemoved")
        }
        nodes.removeSubtree(removedNode)

        guard case let .loaded(children) = parentNode.children else {
            parentNode.updateChildNodeCount(max(0, parentNode.childNodeCount - 1))
            trees.childCountChanged(node: parentNode)
            return .applied
        }
        parentNode.setChildren(children.filter { $0.id != removedID })
        trees.childRemoved(parent: parentNode, nodeID: removedID)
        return .applied
    }

    private func applyShadowRootPushed(
        host: DOM.Node.ID,
        root payload: DOM.Node
    ) -> EventOutcome {
        guard let hostNode = nodes[DOMNode.ID(host)] else {
            return .missingNode(DOMNode.ID(host), reason: "DOM.shadowRootPushed")
        }

        let rootNode = nodes.materialize(payload).node
        hostNode.appendShadowRoot(rootNode)
        trees.childrenReplaced(parent: hostNode)
        return .materializedNodes
    }

    private func applyShadowRootPopped(
        host: DOM.Node.ID,
        root: DOM.Node.ID
    ) -> EventOutcome {
        guard let hostNode = nodes[DOMNode.ID(host)] else {
            return .missingNode(DOMNode.ID(host), reason: "DOM.shadowRootPopped")
        }

        let rootID = DOMNode.ID(root)
        guard let removedRoot = hostNode.removeShadowRoot(id: rootID) ?? nodes[rootID] else {
            return .ignoredGap
        }
        nodes.removeSubtree(removedRoot)
        trees.childrenReplaced(parent: hostNode)
        return .applied
    }

    private func applyPseudoElementAdded(
        parent: DOM.Node.ID,
        element payload: DOM.Node
    ) -> EventOutcome {
        guard let parentNode = nodes[DOMNode.ID(parent)] else {
            return .missingNode(DOMNode.ID(parent), reason: "DOM.pseudoElementAdded")
        }

        let (pseudoElement, materializedPayloadIDs) = nodes.materialize(payload)
        if let replacedElement = parentNode.setPseudoElement(pseudoElement) {
            nodes.removeSubtree(replacedElement, preserving: materializedPayloadIDs)
        }
        trees.childrenReplaced(parent: parentNode)
        return .materializedNodes
    }

    private func applyPseudoElementRemoved(
        parent: DOM.Node.ID,
        element: DOM.Node.ID
    ) -> EventOutcome {
        guard let parentNode = nodes[DOMNode.ID(parent)] else {
            return .missingNode(DOMNode.ID(parent), reason: "DOM.pseudoElementRemoved")
        }

        let elementID = DOMNode.ID(element)
        guard let removedElement = parentNode.removePseudoElement(id: elementID) ?? nodes[elementID] else {
            return .ignoredGap
        }
        nodes.removeSubtree(removedElement)
        trees.childrenReplaced(parent: parentNode)
        return .applied
    }
}

/// The single DOM document load of a context, and the events that arrive
/// while its `DOM.getDocument` reply is in flight.
///
/// Events that reach the context between the request and the reply describe a
/// document that the reply may or may not include. They are buffered in a
/// bootstrap and applied after the document, so none is lost or applied to
/// the previous document.
struct DOMDocumentLoadState {
    private struct Bootstrap {
        var id: UInt64
        var events: [DOM.Event]
    }

    private struct Load {
        var id: UInt64
        var bootstrap: Bootstrap?
    }

    private var load: Load?
    private var nextLoadID: UInt64 = 0
    private var nextBootstrapID: UInt64 = 0

    var isLoading: Bool {
        load != nil
    }

    func isCurrent(_ loadID: UInt64) -> Bool {
        load?.id == loadID
    }

    mutating func begin() -> UInt64 {
        precondition(load == nil, "Only one DOM document load may be active.")
        let id = nextLoadID
        nextLoadID += 1
        load = Load(id: id, bootstrap: nil)
        return id
    }

    mutating func cancel() {
        load = nil
    }

    mutating func finish(_ loadID: UInt64) {
        guard load?.id == loadID else {
            return
        }
        load = nil
    }

    mutating func beginBootstrap(loadID: UInt64) -> UInt64 {
        guard var load else {
            preconditionFailure("DOM bootstrap requires an active document load.")
        }
        precondition(load.id == loadID, "DOM bootstrap must belong to the active document load.")
        precondition(load.bootstrap == nil, "DOM document load already owns a bootstrap.")
        let id = nextBootstrapID
        nextBootstrapID += 1
        load.bootstrap = Bootstrap(id: id, events: [])
        self.load = load
        return id
    }

    mutating func abandonBootstrap(loadID: UInt64, bootstrapID: UInt64) {
        guard load?.id == loadID,
              load?.bootstrap?.id == bootstrapID else {
            return
        }
        load?.bootstrap = nil
    }

    /// Drops the buffered events of the active load, whose document reply no
    /// longer describes the current document.
    mutating func abandonBootstrap() {
        load?.bootstrap = nil
    }

    /// Buffers an event while a bootstrap is active.
    /// - Returns: `false` when no bootstrap is active and the caller applies
    ///   the event itself.
    mutating func buffer(_ event: DOM.Event) -> Bool {
        guard var load, var bootstrap = load.bootstrap else {
            return false
        }
        bootstrap.events.append(event)
        load.bootstrap = bootstrap
        self.load = load
        return true
    }

    /// Ends the load whose document arrived and returns the events to apply
    /// after that document.
    mutating func finishBootstrap(loadID: UInt64, bootstrapID: UInt64) -> [DOM.Event] {
        guard let load, let bootstrap = load.bootstrap else {
            preconditionFailure("Loaded DOM document requires an active bootstrap.")
        }
        precondition(
            load.id == loadID,
            "Loaded DOM document must own the active document load."
        )
        precondition(
            bootstrap.id == bootstrapID,
            "Loaded DOM document must own the active bootstrap."
        )
        self.load = nil
        return bootstrap.events
    }
}
