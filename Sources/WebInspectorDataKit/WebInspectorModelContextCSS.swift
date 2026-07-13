import WebInspectorProxyKit

private enum CSSPropertyMutation {
    case enabled(Bool)
    case declarationText(String)

    func intent(
        for property: CSSStyleProperty,
        in styles: CSSStyles
    ) -> CSSStyles.SetStyleTextIntent? {
        switch self {
        case let .enabled(enabled):
            styles.setStyleTextIntent(for: property, enabled: enabled)
        case let .declarationText(text):
            styles.setDeclarationTextIntent(for: property, text: text)
        }
    }
}

extension WebInspectorModelContext {
    /// Returns the context-local CSS resource owned by an element node.
    public nonisolated(nonsending) func cssStyles(
        for node: DOMNode
    ) async throws -> CSSStyles {
        preconditionOwnerIsolation()
        try requireConfigured(.css)
        _ = try requiredDOMStorage(for: node)
        guard node.nodeType == DOMNode.Kind.element.rawValue else {
            throw WebInspectorModelError.commandRejected(
                method: "CSS.getMatchedStylesForNode",
                message: "CSS styles are available only for element nodes."
            )
        }

        if let styles = node.elementStyles {
            switch styles.phase {
            case .loaded, .needsRefresh:
                return styles
            case .loading, .failed, .unavailable:
                try await loadCSSStyles(for: node, into: styles)
                return styles
            }
        }

        let styles = CSSStyles(nodeID: node.id, modelContext: self)
        node.setElementStyles(styles)
        try await loadCSSStyles(for: node, into: styles)
        return styles
    }

    /// Reloads one existing element-owned CSS resource.
    public nonisolated(nonsending) func refreshCSSStyles(
        for node: DOMNode
    ) async throws {
        preconditionOwnerIsolation()
        try requireConfigured(.css)
        _ = try requiredDOMStorage(for: node)
        guard let styles = node.elementStyles else {
            _ = try await cssStyles(for: node)
            return
        }
        try await loadCSSStyles(for: node, into: styles)
    }

    /// Toggles one current CSS declaration and returns document-scoped undo.
    public nonisolated(nonsending) func setCSSProperty(
        _ property: CSSStyleProperty,
        enabled: Bool,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try await mutateCSSProperty(
            property,
            mutation: .enabled(enabled),
            undo: undo
        )
    }

    /// Replaces one current CSS declaration and returns document-scoped undo.
    public nonisolated(nonsending) func setCSSDeclarationText(
        _ text: String,
        for property: CSSStyleProperty,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try await mutateCSSProperty(
            property,
            mutation: .declarationText(text),
            undo: undo
        )
    }

    private nonisolated(nonsending) func loadCSSStyles(
        for node: DOMNode,
        into styles: CSSStyles
    ) async throws {
        preconditionOwnerIsolation()
        guard styles.modelContext === self,
            node.elementStyles === styles,
            registeredModel(for: node.id) === node
        else {
            throw WebInspectorModelError.staleModel
        }
        guard styles.beginOperation() else {
            throw WebInspectorModelError.commandRejected(
                method: "CSS.getMatchedStylesForNode",
                message: "The CSS resource already has an active operation."
            )
        }
        defer { styles.endOperation() }
        try await loadCSSStylesExclusively(for: node, into: styles)
    }

    private nonisolated(nonsending) func loadCSSStylesExclusively(
        for node: DOMNode,
        into styles: CSSStyles
    ) async throws {
        let nodeID = try requiredDOMStorage(for: node)
        guard styles.modelContext === self,
            node.elementStyles === styles
        else {
            throw WebInspectorModelError.staleModel
        }
        let generation = styles.beginCanonicalLoading()
        do {
            let resource = try await container.core.loadCSSResource(for: nodeID)
            guard registeredModel(for: node.id) === node,
                node.elementStyles === styles,
                styles.modelContext === self,
                styles.load(resource, generation: generation)
            else {
                throw WebInspectorModelError.staleModel
            }
        } catch is CancellationError {
            styles.cancelLoading()
            throw CancellationError()
        } catch {
            throw handleCSSLoadFailure(error, styles: styles)
        }
    }

    private nonisolated(nonsending) func mutateCSSProperty(
        _ property: CSSStyleProperty,
        mutation: CSSPropertyMutation,
        undo: WebInspectorUndoPolicy
    ) async throws -> DOMUndoCapability? {
        preconditionOwnerIsolation()
        try requireConfigured(.css)
        guard let styles = property.ownerStyles,
            styles.modelContext === self,
            let node = model(for: styles.id.nodeID),
            node.elementStyles === styles,
            styles.contains(property: property),
            property.beginMutation()
        else {
            throw WebInspectorModelError.staleModel
        }
        defer { property.endMutation() }
        guard styles.beginOperation() else {
            throw WebInspectorModelError.commandRejected(
                method: "CSS.setStyleText",
                message: "The CSS resource already has an active operation."
            )
        }
        defer { styles.endOperation() }

        if styles.phase != .loaded {
            try await loadCSSStylesExclusively(for: node, into: styles)
        }
        guard let intent = mutation.intent(for: property, in: styles),
            let lease = styles.currentCanonicalLease
        else {
            throw WebInspectorModelError.staleModel
        }

        let result: CSS.Style
        do {
            result = try await container.core.setCSSStyleText(
                intent.text,
                for: intent.styleID,
                resource: lease
            )
        } catch {
            handleCSSMutationFailure(error, styles: styles)
            throw Self.publicDOMError(error, method: "CSS.setStyleText")
        }
        guard styles.modelContext === self,
            registeredModel(for: node.id) === node,
            node.elementStyles === styles,
            styles.currentCanonicalLease == lease,
            styles.contains(property: property)
        else {
            throw WebInspectorModelError.staleModel
        }
        styles.applySetStyleText(result: result, for: property.id)
        try await markDOMUndoableStateIfNeeded(
            in: lease.nodeID.documentScope,
            policy: undo
        )
        return makeDOMUndoCapability(
            in: lease.nodeID.documentScope,
            policy: undo
        )
    }

    private func handleCSSLoadFailure(
        _ error: any Error,
        styles: CSSStyles
    ) -> any Error {
        guard let error = error as? WebInspectorDOMCSSCommandError else {
            if let error = error as? WebInspectorProxyError {
                styles.fail(error)
            } else {
                styles.markUnavailable()
            }
            return error
        }
        switch error {
        case .staleCascade:
            styles.markCanonicalNeedsRefresh()
        case let .proxy(proxyError):
            styles.fail(proxyError)
        case .authorization, .invalidReply:
            let proxyError = WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method:
                    "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            )
            styles.fail(proxyError)
            return proxyError
        case .closed, .detached, .domainNotConfigured, .foreignStore,
            .staleDocument, .nodeNotFound, .styleSheetNotFound,
            .agentTargetUnavailable, .identityRouteMismatch, .staleNode,
            .staleStyleSheet:
            styles.markUnavailable()
        }
        return Self.publicDOMError(
            error,
            method:
                "CSS.getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode"
        )
    }

    private func handleCSSMutationFailure(
        _ error: any Error,
        styles: CSSStyles
    ) {
        guard let error = error as? WebInspectorDOMCSSCommandError else {
            return
        }
        switch error {
        case .staleCascade:
            styles.markCanonicalNeedsRefresh()
        case .closed, .detached, .foreignStore, .staleDocument,
            .nodeNotFound, .identityRouteMismatch, .staleNode:
            styles.markUnavailable()
        case .domainNotConfigured, .styleSheetNotFound,
            .agentTargetUnavailable, .staleStyleSheet, .proxy,
            .authorization, .invalidReply:
            break
        }
    }
}
