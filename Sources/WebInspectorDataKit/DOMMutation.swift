/// Controls how DOM selection changes should be revealed to UI tree views.
public enum DOMRevealPolicy: Sendable, Hashable {
    /// Do not reveal or select the node.
    case none

    /// Select the node without requesting scrolling.
    case selectOnly

    /// Select and request scrolling the node into view.
    case selectAndScroll
}

/// The accepted subset of a requested DOM mutation.
public struct DOMMutationResult: Sendable, Hashable {
    /// Node identities requested by the caller.
    public var requestedNodeIDs: [DOMNode.ID]

    /// Node identities accepted by the backend mutation.
    public var acceptedNodeIDs: [DOMNode.ID]

    /// Creates a DOM mutation result.
    public init(requestedNodeIDs: [DOMNode.ID], acceptedNodeIDs: [DOMNode.ID]) {
        self.requestedNodeIDs = requestedNodeIDs
        self.acceptedNodeIDs = acceptedNodeIDs
    }
}
