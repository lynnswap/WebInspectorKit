/// Controls how DOM selection changes should be revealed to UI tree views.
public enum DOMRevealPolicy: Sendable, Hashable {
    /// Do not reveal or select the node.
    case none

    /// Select the node without requesting scrolling.
    case selectOnly

    /// Select and request scrolling the node into view.
    case selectAndScroll
}

/// One node-specific failure from a multi-node DOM mutation.
public struct DOMMutationFailure: Error, Hashable, Sendable {
    public let nodeID: DOMNode.ID
    public let message: String

    public init(nodeID: DOMNode.ID, message: String) {
        self.nodeID = nodeID
        self.message = message
    }
}

/// Text representations supported by the DOM feature facade.
public enum DOMTextRepresentation: Hashable, Sendable {
    case html
    case selectorPath
    case xPath
}

/// A document-epoch-bound capability for undoing one accepted DOM/CSS change.
public final class DOMUndoCapability: Sendable {
    private let owner: WebInspectorDOMFeature
    private let scope: WebInspectorDOMDocumentScopeStorage

    package init(
        owner: WebInspectorDOMFeature,
        scope: WebInspectorDOMDocumentScopeStorage
    ) {
        self.owner = owner
        self.scope = scope
    }

    public func undo() async throws {
        try await owner.undo(in: scope)
    }

    public func redo() async throws {
        try await owner.redo(in: scope)
    }
}

/// The applied subset and explicit failures from a requested DOM mutation.
public struct DOMMutationOutcome: Sendable {
    public let requestedNodeIDs: [DOMNode.ID]
    public let appliedNodeIDs: [DOMNode.ID]
    public let failures: [DOMMutationFailure]
    public let undo: DOMUndoCapability?

    public init(
        requestedNodeIDs: [DOMNode.ID],
        appliedNodeIDs: [DOMNode.ID],
        failures: [DOMMutationFailure],
        undo: DOMUndoCapability?
    ) {
        self.requestedNodeIDs = requestedNodeIDs
        self.appliedNodeIDs = appliedNodeIDs
        self.failures = failures
        self.undo = undo
    }
}
