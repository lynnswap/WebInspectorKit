import WebInspectorProxyKit

extension WebInspectorModelContext {
    /// Returns this context's current model for a stable DOM identity.
    public func domNode(id: DOMNode.ID) throws -> DOMNode? {
        preconditionOwnerIsolation()
        try requireConfigured(.dom)
        return model(for: id)
    }

    package func requiredNode(for id: DOMNode.ID) throws -> DOMNode {
        preconditionOwnerIsolation()
        try requireConfigured(.dom)
        guard let node = model(for: id)
        else {
            throw WebInspectorModelError.staleModel
        }
        return node
    }

    /// Requests child nodes without changing UI selection.
    public nonisolated(nonsending) func requestDOMChildren(
        of node: DOMNode,
        depth: Int = 1
    ) async throws {
        preconditionOwnerIsolation()
        precondition(depth >= 0, "DOM child request depth must be non-negative.")
        let storage = try requiredDOMStorage(for: node)
        do {
            try await container.core.requestDOMChildren(
                of: storage,
                depth: depth
            )
        } catch {
            throw Self.publicDOMError(error, method: "DOM.requestChildNodes")
        }
    }

    /// Sets one DOM attribute and returns its document-bound undo capability.
    public nonisolated(nonsending) func setDOMAttribute(
        _ name: String,
        value: String,
        on node: DOMNode,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        preconditionOwnerIsolation()
        let storage = try requiredDOMStorage(for: node)
        do {
            try await container.core.setDOMAttributeValue(
                name,
                value: value,
                on: storage
            )
            try await markDOMUndoableStateIfNeeded(
                in: storage.documentScope,
                policy: undo
            )
        } catch {
            throw Self.publicDOMError(error, method: "DOM.setAttributeValue")
        }
        return successfulDOMMutation(
            nodeIDs: [node.id],
            scope: storage.documentScope,
            policy: undo
        )
    }

    /// Replaces one node's outer HTML.
    public nonisolated(nonsending) func setOuterHTML(
        _ html: String,
        of node: DOMNode,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        preconditionOwnerIsolation()
        let storage = try requiredDOMStorage(for: node)
        do {
            try await container.core.setDOMOuterHTML(html, of: storage)
            try await markDOMUndoableStateIfNeeded(
                in: storage.documentScope,
                policy: undo
            )
        } catch {
            throw Self.publicDOMError(error, method: "DOM.setOuterHTML")
        }
        return successfulDOMMutation(
            nodeIDs: [node.id],
            scope: storage.documentScope,
            policy: undo
        )
    }

    /// Removes current nodes deepest-first and reports node-specific failures.
    public nonisolated(nonsending) func removeDOMNodes(
        _ nodes: [DOMNode],
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        preconditionOwnerIsolation()
        try requireConfigured(.dom)
        var seen: Set<DOMNode.ID> = []
        let resources = try nodes
            .filter { seen.insert($0.id).inserted }
            .map { node in
                (node, try requiredDOMStorage(for: node))
            }
        let scope = try commonDocumentScope(resources.map(\.1))
        let snapshot = domTreeSnapshot
        let sorted = try resources.sorted { lhs, rhs in
            try domTreeDepth(of: lhs.0.id, in: snapshot)
                > domTreeDepth(of: rhs.0.id, in: snapshot)
        }

        var applied: [DOMNode.ID] = []
        var failures: [DOMMutationFailure] = []
        for (node, storage) in sorted {
            do {
                try await container.core.removeDOMNode(storage)
                try await markDOMUndoableStateIfNeeded(
                    in: storage.documentScope,
                    policy: undo
                )
                applied.append(node.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(
                    DOMMutationFailure(
                        nodeID: node.id,
                        message: String(
                            describing: Self.publicDOMError(
                                error,
                                method: "DOM.removeNode"
                            )
                        )
                    )
                )
            }
        }
        return DOMMutationOutcome(
            requestedNodeIDs: nodes.map(\.id),
            appliedNodeIDs: applied,
            failures: failures,
            undo: applied.isEmpty ? nil : scope.flatMap {
                makeDOMUndoCapability(in: $0, policy: undo)
            }
        )
    }

    /// Returns copied text for a DOM node in the requested format.
    public nonisolated(nonsending) func copyText(
        _ kind: DOMNode.CopyTextKind,
        for node: DOMNode
    ) async throws -> String {
        preconditionOwnerIsolation()
        let storage = try requiredDOMStorage(for: node)
        switch kind {
        case .html:
            do {
                return try await container.core.domOuterHTML(of: storage)
            } catch {
                throw Self.publicDOMError(error, method: "DOM.getOuterHTML")
            }
        case .selectorPath:
            return domTreeSnapshot.selectorPath(for: node.id)
        case .xPath:
            return domTreeSnapshot.xPath(for: node.id)
        }
    }

    package func copyText(
        _ kind: DOMNode.CopyTextKind,
        for id: DOMNode.ID
    ) async throws -> String {
        try await copyText(kind, for: try requiredNode(for: id))
    }

    /// Highlights a current node in the inspected page.
    public nonisolated(nonsending) func highlightDOMNode(
        _ node: DOMNode
    ) async throws {
        preconditionOwnerIsolation()
        let storage = try requiredDOMStorage(for: node)
        do {
            try await container.core.highlightDOMNode(storage)
        } catch {
            throw Self.publicDOMError(error, method: "DOM.highlightNode")
        }
    }

    /// Clears the inspected page's DOM highlight.
    public nonisolated(nonsending) func hideDOMHighlight() async throws {
        preconditionOwnerIsolation()
        try requireConfigured(.dom)
        do {
            try await container.core.hideDOMHighlight()
        } catch {
            throw Self.publicDOMError(error, method: "DOM.hideHighlight")
        }
    }

    package nonisolated(nonsending) func pickDOMNodeID() async throws
        -> DOMNode.ID?
    {
        preconditionOwnerIsolation()
        try requireConfigured(.dom)
        do {
            return try await container.core.pickDOMNode().map {
                DOMNode.ID(canonical: $0)
            }
        } catch {
            throw Self.publicElementPickerError(error)
        }
    }

    /// Reloads the inspected page.
    public nonisolated(nonsending) func reload(
        ignoringCache: Bool = false
    ) async throws {
        preconditionOwnerIsolation()
        do {
            try await container.core.reloadPage(ignoringCache: ignoringCache)
        } catch {
            throw Self.publicDOMError(error, method: "Page.reload")
        }
    }

    /// Returns a CSS selector path from the context's current tree projection.
    public func selectorPath(for node: DOMNode) throws -> String {
        _ = try requiredDOMStorage(for: node)
        return domTreeSnapshot.selectorPath(for: node.id)
    }

    package func selectorPath(for id: DOMNode.ID) throws -> String {
        try selectorPath(for: requiredNode(for: id))
    }

    /// Returns an XPath from the context's current tree projection.
    public func xPath(for node: DOMNode) throws -> String {
        _ = try requiredDOMStorage(for: node)
        return domTreeSnapshot.xPath(for: node.id)
    }

    package func xPath(for id: DOMNode.ID) throws -> String {
        try xPath(for: requiredNode(for: id))
    }

    package func requiredDOMStorage(
        for node: DOMNode
    ) throws -> WebInspectorDOMNodeIdentityStorage {
        preconditionOwnerIsolation()
        try requireConfigured(.dom)
        guard registeredModel(for: node.id) === node
        else {
            throw WebInspectorModelError.staleModel
        }
        return node.id.canonicalStorage
    }

    private func successfulDOMMutation(
        nodeIDs: [DOMNode.ID],
        scope: WebInspectorDOMDocumentScopeStorage,
        policy: WebInspectorUndoPolicy
    ) -> DOMMutationOutcome {
        DOMMutationOutcome(
            requestedNodeIDs: nodeIDs,
            appliedNodeIDs: nodeIDs,
            failures: [],
            undo: makeDOMUndoCapability(in: scope, policy: policy)
        )
    }

    package func makeDOMUndoCapability(
        in scope: WebInspectorDOMDocumentScopeStorage,
        policy: WebInspectorUndoPolicy
    ) -> DOMUndoCapability? {
        guard policy == .automatic else {
            return nil
        }
        return DOMUndoCapability(core: container.core, scope: scope)
    }

    package nonisolated(nonsending) func markDOMUndoableStateIfNeeded(
        in scope: WebInspectorDOMDocumentScopeStorage,
        policy: WebInspectorUndoPolicy
    ) async throws {
        guard policy == .automatic else {
            return
        }
        try await container.core.markDOMUndoableState(in: scope)
    }

    private func commonDocumentScope(
        _ nodeIDs: [WebInspectorDOMNodeIdentityStorage]
    ) throws -> WebInspectorDOMDocumentScopeStorage? {
        guard let scope = nodeIDs.first?.documentScope else {
            return nil
        }
        guard nodeIDs.dropFirst().allSatisfy({
            $0.documentScope == scope
        }) else {
            throw WebInspectorModelError.commandRejected(
                method: "DOM.removeNode",
                message: "A mutation cannot span multiple DOM documents."
            )
        }
        return scope
    }

    private func domTreeDepth(
        of id: DOMNode.ID,
        in snapshot: WebInspectorDOMTreeSnapshot
    ) throws -> Int {
        guard snapshot.rowsByID[id] != nil else {
            throw WebInspectorModelError.staleModel
        }
        var depth = 0
        var visited: Set<DOMNode.ID> = [id]
        var current = snapshot.rowsByID[id]?.parentID
        while let ancestorID = current {
            guard visited.insert(ancestorID).inserted,
                let ancestor = snapshot.rowsByID[ancestorID]
            else {
                throw WebInspectorModelError.staleModel
            }
            depth += 1
            current = ancestor.parentID
        }
        return depth
    }

    package nonisolated static func publicDOMError(
        _ error: any Error,
        method: String
    ) -> any Error {
        guard let error = error as? WebInspectorDOMCSSCommandError else {
            return error
        }
        switch error {
        case .closed, .staleDocument, .nodeNotFound, .styleSheetNotFound,
            .foreignStore, .identityRouteMismatch, .staleNode,
            .staleStyleSheet, .staleCascade:
            return WebInspectorModelError.staleModel
        case .detached, .agentTargetUnavailable:
            return WebInspectorModelError.detached
        case let .domainNotConfigured(domain):
            return WebInspectorModelError.domainNotConfigured(
                publicDOMDomain(domain)
            )
        case let .proxy(error):
            return error
        case let .authorization(error):
            return WebInspectorModelError.commandRejected(
                method: method,
                message: String(describing: error)
            )
        case let .invalidReply(message):
            return WebInspectorModelError.commandRejected(
                method: method,
                message: message
            )
        }
    }

    private nonisolated static func publicElementPickerError(
        _ error: any Error
    ) -> any Error {
        guard let error = error as? WebInspectorElementPickerError else {
            return error
        }
        switch error {
        case .closed, .detached, .domainNotConfigured,
            .operationAlreadyActive, .staleDocument, .nodeNotFound,
            .feedFailure, .proxy, .authorization, .invalidReply:
            return error
        }
    }

    package nonisolated static func publicDOMDomain(
        _ domain: ModelDomain
    ) -> WebInspectorModelContainer.Domain {
        switch domain {
        case .dom:
            return .dom
        case .css:
            return .css
        case .network:
            return .network
        case .console:
            return .console
        case .runtime:
            return .runtime
        }
    }
}
