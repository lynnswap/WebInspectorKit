import WebInspectorProxyKit

package enum WebInspectorDOMCSSCommandError: Error, Equatable, Sendable {
    case closed
    case detached
    case domainNotConfigured(ModelDomain)
    case foreignStore
    case staleDocument
    case nodeNotFound
    case styleSheetNotFound
    case agentTargetUnavailable(WebInspectorTarget.ID)
    case identityRouteMismatch
    case staleNode
    case staleStyleSheet
    case staleCascade
    case proxy(WebInspectorProxyError)
    case authorization(ConnectionModelCommandError)
    case invalidReply(String)
}

/// One exact node/cascade version used to load a coherent CSS presentation.
///
/// The value is package-only until context-local model materialization owns
/// the public CSS resource lifecycle. It deliberately contains canonical
/// identity rather than a target-prefixed compatibility identifier.
package struct WebInspectorCanonicalCSSResourceLease: Hashable, Sendable {
    package let nodeID: WebInspectorDOMNodeIdentityStorage
    package let cascadeRevision: UInt64
    package let presentationRevision: WebInspectorCanonicalPresentationRevision

    package init(
        nodeID: WebInspectorDOMNodeIdentityStorage,
        cascadeRevision: UInt64,
        presentationRevision: WebInspectorCanonicalPresentationRevision
    ) {
        self.nodeID = nodeID
        self.cascadeRevision = cascadeRevision
        self.presentationRevision = presentationRevision
    }
}

package struct WebInspectorCanonicalCSSResource: Sendable {
    package let lease: WebInspectorCanonicalCSSResourceLease
    package let matchedStyles: CSS.MatchedStyles
    package let inlineStyles: CSS.InlineStyles
    package let computedProperties: [CSS.ComputedProperty]

    package init(
        lease: WebInspectorCanonicalCSSResourceLease,
        matchedStyles: CSS.MatchedStyles,
        inlineStyles: CSS.InlineStyles,
        computedProperties: [CSS.ComputedProperty]
    ) {
        self.lease = lease
        self.matchedStyles = matchedStyles
        self.inlineStyles = inlineStyles
        self.computedProperties = computedProperties
    }
}

struct WebInspectorDOMCSSCommandRoute: Sendable {
    enum CompletionValidation: Sendable {
        case attachment
        case document(WebInspectorDOMDocumentScopeStorage)
        case node(WebInspectorDOMNodeIdentityStorage)
        case nodeRead(WebInspectorDOMNodeIdentityStorage)
        case styleSheet(WebInspectorCSSStyleSheetIdentityStorage)
        case cssResource(WebInspectorCanonicalCSSResourceLease)
    }

    let validation: CompletionValidation
    let resourceID: UInt64
    let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    let pageGeneration: WebInspectorPage.Generation
    let agentTarget: ModelTarget
    let documentScope: WebInspectorDOMDocumentScopeStorage?
    let proxy: WebInspectorProxy
    let feedID: ConnectionModelFeedID

    func hasSameAuthority(
        as other: WebInspectorDOMCSSCommandRoute
    ) -> Bool {
        resourceID == other.resourceID
            && attachmentGeneration == other.attachmentGeneration
            && pageGeneration == other.pageGeneration
            && agentTarget == other.agentTarget
            && documentScope == other.documentScope
            && proxy === other.proxy
            && feedID == other.feedID
    }

    var target: WebInspectorTarget {
        let document = documentScope.map {
            ConnectionModelCommandAuthorization.Document(
                targetID: agentTarget.id,
                epoch: $0.domBindingEpoch
            )
        }
        return proxy.modelTarget(
            agentTarget,
            authorization: ConnectionModelCommandAuthorization(
                feedID: feedID,
                generation: pageGeneration,
                document: document
            )
        )
    }

    var staleCompletionError: WebInspectorDOMCSSCommandError {
        switch validation {
        case .attachment:
            .detached
        case .document:
            .staleDocument
        case .node, .nodeRead:
            .staleNode
        case .styleSheet:
            .staleStyleSheet
        case .cssResource:
            .staleCascade
        }
    }
}

struct WebInspectorDOMCSSCommandOperation: Sendable {
    let route: WebInspectorDOMCSSCommandRoute
    let completionOnRetirement: @Sendable (WebInspectorDOMCSSCommandError) -> Bool
    let task: Task<Void, Never>
    var isRetired: Bool
}

package extension WebInspectorModelContainerCore {
    func reloadPage(ignoringCache: Bool) async throws {
        try Task.checkCancellation()
        let route = try domAttachmentCommandRoute()
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.page.reload(ignoringCache: ignoringCache)
        }
        try await completion.value()
    }

    /// Requests child-node delivery for one current canonical node.
    func requestDOMChildren(
        of nodeID: WebInspectorDOMNodeIdentityStorage,
        depth: Int = 1
    ) async throws {
        precondition(depth >= 0, "DOM child request depth must be non-negative.")
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .node(nodeID)
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.requestChildNodes(
                nodeID.rawNodeID,
                depth: depth
            )
        }
        try await completion.value()
    }

    func domOuterHTML(
        of nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws -> String {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .nodeRead(nodeID)
        )
        let completion: ReplyPromise<String> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.outerHTML(of: nodeID.rawNodeID)
        }
        return try await completion.value()
    }

    func domAttributes(
        of nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws -> [DOM.Attribute] {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .nodeRead(nodeID)
        )
        let completion: ReplyPromise<[DOM.Attribute]> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.attributes(of: nodeID.rawNodeID)
        }
        return try await completion.value()
    }

    func setDOMAttributeValue(
        _ name: String,
        value: String,
        on nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .node(nodeID)
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.setAttributeValue(
                nodeID.rawNodeID,
                name: name,
                value: value
            )
        }
        try await completion.value()
    }

    func setDOMAttributesAsText(
        _ text: String,
        name: String? = nil,
        on nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .node(nodeID)
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.setAttributesAsText(
                nodeID.rawNodeID,
                text: text,
                name: name
            )
        }
        try await completion.value()
    }

    func removeDOMAttribute(
        _ name: String,
        from nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .node(nodeID)
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.removeAttribute(
                nodeID.rawNodeID,
                name: name
            )
        }
        try await completion.value()
    }

    /// Replacing outer HTML may retire the addressed node before the success
    /// reply. The document lease, not post-replacement node membership, owns
    /// completion validity.
    func setDOMOuterHTML(
        _ html: String,
        of nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .document(nodeID.documentScope)
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.setOuterHTML(
                nodeID.rawNodeID,
                html: html
            )
        }
        try await completion.value()
    }

    /// Removal success is bound to the document that accepted the command;
    /// requiring the deleted node after the reply would reject valid success.
    func removeDOMNode(
        _ nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .document(nodeID.documentScope)
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.removeNode(nodeID.rawNodeID)
        }
        try await completion.value()
    }

    func markDOMUndoableState(
        in scope: WebInspectorDOMDocumentScopeStorage
    ) async throws {
        try await performDOMDocumentCommand(in: scope) { target in
            try await target.dom.markUndoableState()
        }
    }

    func undoDOMChange(
        in scope: WebInspectorDOMDocumentScopeStorage
    ) async throws {
        try await performDOMDocumentCommand(in: scope) { target in
            try await target.dom.undo()
        }
    }

    func redoDOMChange(
        in scope: WebInspectorDOMDocumentScopeStorage
    ) async throws {
        try await performDOMDocumentCommand(in: scope) { target in
            try await target.dom.redo()
        }
    }

    /// Highlights a node admitted from current canonical membership. Once the
    /// wire reply succeeds, only the attachment/feed lease matters: a later
    /// DOM event may legitimately replace that node without invalidating the
    /// already-applied page highlight.
    func highlightDOMNode(
        _ nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws {
        try Task.checkCancellation()
        let route = try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .attachment
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.highlightNode(nodeID.rawNodeID)
        }
        try await completion.value()
    }

    func hideDOMHighlight() async throws {
        try Task.checkCancellation()
        let route = try domAttachmentCommandRoute()
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.hideHighlight()
        }
        try await completion.value()
    }

    /// Loads matched, inline, and computed styles as one node/cascade-bound
    /// resource. Concurrent callers coalesce only when the complete canonical
    /// lease is equal.
    func loadCSSResource(
        for nodeID: WebInspectorDOMNodeIdentityStorage
    ) async throws -> WebInspectorCanonicalCSSResource {
        try Task.checkCancellation()
        let route = try cssResourceCommandRoute(for: nodeID)
        let lease: WebInspectorCanonicalCSSResourceLease
        guard case let .cssResource(value) = route.validation else {
            preconditionFailure("A CSS resource route lost its lease.")
        }
        lease = value

        if let operationID = domCSSOperationIDByCSSResourceLease[lease] {
            guard let operation = domCSSCommandOperations[operationID],
                !operation.isRetired,
                operation.route.hasSameAuthority(as: route),
                let completion = domCSSResourceCompletions[operationID]
            else {
                preconditionFailure(
                    "A canonical CSS resource lease lost its active operation."
                )
            }
            performanceCounters.domCSSCommandCoalescedWaiterCount += 1
            return try await completion.value()
        }

        let completion: ReplyPromise<WebInspectorCanonicalCSSResource> =
            startDOMCSSCommand(route: route) { target in
                async let matched = target.css.matchedStyles(
                    for: nodeID.rawNodeID
                )
                async let inline = target.css.inlineStyles(
                    for: nodeID.rawNodeID
                )
                async let computed = target.css.computedStyle(
                    for: nodeID.rawNodeID
                )
                return try await WebInspectorCanonicalCSSResource(
                    lease: lease,
                    matchedStyles: matched,
                    inlineStyles: inline,
                    computedProperties: computed
                )
            }
        guard let operationID = domCSSOperationIDByCSSResourceLease[lease]
        else {
            preconditionFailure(
                "A new canonical CSS resource operation lost its lease index."
            )
        }
        domCSSResourceCompletions[operationID] = completion
        return try await completion.value()
    }

    func setCSSStyleSheetText(
        _ text: String,
        for styleSheetID: WebInspectorCSSStyleSheetIdentityStorage
    ) async throws {
        try Task.checkCancellation()
        let route = try cssStyleSheetCommandRoute(for: styleSheetID)
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.css.setStyleSheetText(
                styleSheetID.rawStyleSheetID,
                text: text
            )
        }
        try await completion.value()
    }
}

extension WebInspectorModelContainerCore {
    func performDOMDocumentCommand(
        in scope: WebInspectorDOMDocumentScopeStorage,
        operation: @escaping @Sendable (WebInspectorTarget) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let route = try domDocumentCommandRoute(
            for: scope,
            completionValidation: .document(scope)
        )
        let completion: ReplyPromise<Void> = startDOMCSSCommand(
            route: route,
            operation: operation
        )
        try await completion.value()
    }

    func startDOMCSSCommand<Output: Sendable>(
        route: WebInspectorDOMCSSCommandRoute,
        operation: @escaping @Sendable (WebInspectorTarget) async throws -> Output
    ) -> ReplyPromise<Output> {
        precondition(
            nextDOMCSSCommandOperationID < UInt64.max,
            "Model Container Core exhausted DOM/CSS operation identifiers."
        )
        nextDOMCSSCommandOperationID += 1
        let operationID = nextDOMCSSCommandOperationID
        let completion = ReplyPromise<Output>()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Output, WebInspectorDOMCSSCommandError>
            do {
                result = .success(try await operation(route.target))
            } catch WebInspectorProxyError.staleIdentifier {
                result = .failure(route.staleCompletionError)
            } catch let error as WebInspectorProxyError {
                result = .failure(.proxy(error))
            } catch let error as ConnectionModelCommandError {
                result = .failure(.authorization(error))
            } catch is CancellationError {
                result = .failure(.staleDocument)
            } catch {
                result = .failure(.invalidReply(String(reflecting: error)))
            }
            guard let self else {
                _ = completion.fulfill(
                    .failure(WebInspectorDOMCSSCommandError.closed)
                )
                return
            }
            await self.finishDOMCSSCommand(
                operationID,
                result: result,
                completion: completion
            )
        }
        let storedOperation = WebInspectorDOMCSSCommandOperation(
            route: route,
            completionOnRetirement: { error in
                completion.fulfill(.failure(error))
            },
            task: task,
            isRetired: false
        )
        precondition(
            domCSSCommandOperations[operationID] == nil,
            "A DOM/CSS operation identifier was reused."
        )
        domCSSCommandOperations[operationID] = storedOperation
        if case let .cssResource(lease) = route.validation {
            precondition(
                domCSSOperationIDByCSSResourceLease[lease] == nil,
                "A CSS resource lease admitted two wire operations."
            )
            domCSSOperationIDByCSSResourceLease[lease] = operationID
        }
        performanceCounters.domCSSCommandWireOperationCount += 1
        return completion
    }

    func finishDOMCSSCommand<Output: Sendable>(
        _ operationID: UInt64,
        result: Result<Output, WebInspectorDOMCSSCommandError>,
        completion: ReplyPromise<Output>
    ) {
        guard
            let operation = domCSSCommandOperations.removeValue(
                forKey: operationID
            )
        else {
            preconditionFailure(
                "A DOM/CSS operation completed without its Core owner."
            )
        }
        removeDOMCSSResourceIndexes(
            for: operation,
            operationID: operationID
        )
        guard !operation.isRetired else {
            return
        }

        if let validationError = domCSSCompletionError(
            for: operation.route
        ) {
            precondition(
                completion.fulfill(.failure(validationError)),
                "A current DOM/CSS operation completed twice."
            )
        } else {
            precondition(
                completion.fulfill(result.mapError { $0 as any Error }),
                "A current DOM/CSS operation completed twice."
            )
        }
    }

    func domAttachmentCommandRoute()
        throws -> WebInspectorDOMCSSCommandRoute
    {
        guard !isConnectionCloseRequested,
            lifecycleAllowsDOMCSSCommands
        else {
            throw WebInspectorDOMCSSCommandError.closed
        }
        guard configuredDomains.contains(.dom) else {
            throw WebInspectorDOMCSSCommandError.domainNotConfigured(.dom)
        }
        guard let resource = activeAttachment,
            let binding = canonicalStore.bindingSnapshot
        else {
            throw WebInspectorDOMCSSCommandError.detached
        }
        guard let currentPageID = binding.currentPageID,
            let target = binding.targets.lazy.map(\.target).first(
                where: { $0.id == currentPageID }
            )
        else {
            throw WebInspectorDOMCSSCommandError.detached
        }
        return WebInspectorDOMCSSCommandRoute(
            validation: .attachment,
            resourceID: resource.id,
            attachmentGeneration: resource.generation,
            pageGeneration: binding.pageGeneration,
            agentTarget: target,
            documentScope: nil,
            proxy: resource.proxyLease.proxy,
            feedID: resource.feed.id
        )
    }

    func domDocumentCommandRoute(
        for scope: WebInspectorDOMDocumentScopeStorage,
        completionValidation: WebInspectorDOMCSSCommandRoute.CompletionValidation
    ) throws -> WebInspectorDOMCSSCommandRoute {
        guard !isConnectionCloseRequested,
            lifecycleAllowsDOMCSSCommands
        else {
            throw WebInspectorDOMCSSCommandError.closed
        }
        guard configuredDomains.contains(.dom) else {
            throw WebInspectorDOMCSSCommandError.domainNotConfigured(.dom)
        }
        guard scope.storeID == storeID else {
            throw WebInspectorDOMCSSCommandError.foreignStore
        }
        guard let resource = activeAttachment,
            let binding = canonicalStore.bindingSnapshot
        else {
            throw WebInspectorDOMCSSCommandError.detached
        }
        guard resource.generation == scope.attachmentGeneration,
            binding.attachmentGeneration == scope.attachmentGeneration,
            binding.pageGeneration == scope.pageGeneration,
            canonicalStore.domRoot(in: scope) != nil
        else {
            throw WebInspectorDOMCSSCommandError.staleDocument
        }
        guard
            let agentState = binding.targets.first(
                where: { $0.target.id == scope.agentTargetID }
            ),
            agentState.domBindingEpoch == scope.domBindingEpoch,
            binding.targets.contains(
                where: { $0.target.id == scope.semanticTargetID }
            )
        else {
            throw WebInspectorDOMCSSCommandError.agentTargetUnavailable(
                scope.agentTargetID
            )
        }
        return WebInspectorDOMCSSCommandRoute(
            validation: completionValidation,
            resourceID: resource.id,
            attachmentGeneration: resource.generation,
            pageGeneration: binding.pageGeneration,
            agentTarget: agentState.target,
            documentScope: scope,
            proxy: resource.proxyLease.proxy,
            feedID: resource.feed.id
        )
    }

    func domNodeCommandRoute(
        for nodeID: WebInspectorDOMNodeIdentityStorage,
        completionValidation: WebInspectorDOMCSSCommandRoute.CompletionValidation
    ) throws -> WebInspectorDOMCSSCommandRoute {
        let route = try domDocumentCommandRoute(
            for: nodeID.documentScope,
            completionValidation: completionValidation
        )
        guard canonicalStore.domRecord(for: nodeID) != nil else {
            throw WebInspectorDOMCSSCommandError.nodeNotFound
        }
        guard
            nodeID.rawNodeID.targetScopeRawValue == nil
                || nodeID.rawNodeID.targetScopeRawValue
                    == nodeID.documentScope.agentTargetID.rawValue
        else {
            throw WebInspectorDOMCSSCommandError.identityRouteMismatch
        }
        return route
    }

    func cssResourceCommandRoute(
        for nodeID: WebInspectorDOMNodeIdentityStorage
    ) throws -> WebInspectorDOMCSSCommandRoute {
        guard configuredDomains.contains(.css) else {
            throw WebInspectorDOMCSSCommandError.domainNotConfigured(.css)
        }
        guard canonicalStore.domRecord(for: nodeID) != nil else {
            if nodeID.documentScope.storeID != storeID {
                throw WebInspectorDOMCSSCommandError.foreignStore
            }
            throw WebInspectorDOMCSSCommandError.nodeNotFound
        }
        guard
            let cascadeRevision = canonicalStore.cssCascadeRevision(
                in: nodeID.documentScope
            ),
            let presentationRevision = canonicalStore.presentationRevision(
                for: nodeID
            )
        else {
            throw WebInspectorDOMCSSCommandError.staleCascade
        }
        let lease = WebInspectorCanonicalCSSResourceLease(
            nodeID: nodeID,
            cascadeRevision: cascadeRevision,
            presentationRevision: presentationRevision
        )
        return try domNodeCommandRoute(
            for: nodeID,
            completionValidation: .cssResource(lease)
        )
    }

    func cssStyleSheetCommandRoute(
        for styleSheetID: WebInspectorCSSStyleSheetIdentityStorage
    ) throws -> WebInspectorDOMCSSCommandRoute {
        guard configuredDomains.contains(.css) else {
            throw WebInspectorDOMCSSCommandError.domainNotConfigured(.css)
        }
        let route = try domDocumentCommandRoute(
            for: styleSheetID.documentScope,
            completionValidation: .styleSheet(styleSheetID)
        )
        guard canonicalStore.cssStyleSheetRecord(for: styleSheetID) != nil else {
            throw WebInspectorDOMCSSCommandError.styleSheetNotFound
        }
        guard
            styleSheetID.rawStyleSheetID.targetScopeRawValue == nil
                || styleSheetID.rawStyleSheetID.targetScopeRawValue
                    == styleSheetID.documentScope.agentTargetID.rawValue
        else {
            throw WebInspectorDOMCSSCommandError.identityRouteMismatch
        }
        return route
    }

    var lifecycleAllowsDOMCSSCommands: Bool {
        acceptsDOMCSSCommands
            && connectionState == .attached
            && activeAttachment != nil
    }

    func domCSSCompletionError(
        for route: WebInspectorDOMCSSCommandRoute
    ) -> WebInspectorDOMCSSCommandError? {
        if isConnectionCloseRequested {
            return .closed
        }
        guard let resource = activeAttachment,
            resource.id == route.resourceID,
            resource.generation == route.attachmentGeneration,
            resource.feed.id == route.feedID,
            resource.proxyLease.proxy === route.proxy,
            let binding = canonicalStore.bindingSnapshot,
            binding.attachmentGeneration == route.attachmentGeneration,
            binding.pageGeneration == route.pageGeneration
        else {
            return .detached
        }

        switch route.validation {
        case .attachment:
            return nil
        case let .document(scope):
            return isCurrentDOMDocument(scope, route: route)
                ? nil
                : .staleDocument
        case let .node(nodeID):
            guard isCurrentDOMDocument(nodeID.documentScope, route: route),
                canonicalStore.domRecord(for: nodeID) != nil
            else {
                return .staleNode
            }
            return nil
        case let .nodeRead(nodeID):
            guard isCurrentDOMDocument(nodeID.documentScope, route: route),
                canonicalStore.domRecord(for: nodeID) != nil
            else {
                return .staleNode
            }
            return nil
        case let .styleSheet(styleSheetID):
            guard
                isCurrentDOMDocument(
                    styleSheetID.documentScope,
                    route: route
                ),
                canonicalStore.cssStyleSheetRecord(for: styleSheetID) != nil
            else {
                return .staleStyleSheet
            }
            return nil
        case let .cssResource(lease):
            guard
                isCurrentDOMDocument(
                    lease.nodeID.documentScope,
                    route: route
                ),
                canonicalStore.domRecord(for: lease.nodeID) != nil,
                canonicalStore.cssCascadeRevision(
                    in: lease.nodeID.documentScope
                ) == lease.cascadeRevision,
                canonicalStore.presentationRevision(for: lease.nodeID)
                    == lease.presentationRevision
            else {
                return .staleCascade
            }
            return nil
        }
    }

    func isCurrentDOMDocument(
        _ scope: WebInspectorDOMDocumentScopeStorage,
        route: WebInspectorDOMCSSCommandRoute
    ) -> Bool {
        guard scope.storeID == storeID,
            scope.attachmentGeneration == route.attachmentGeneration,
            scope.pageGeneration == route.pageGeneration,
            scope.agentTargetID == route.agentTarget.id,
            let binding = canonicalStore.bindingSnapshot,
            binding.targets.contains(where: {
                $0.target.id == scope.semanticTargetID
            }),
            binding.targets.contains(where: {
                $0.target == route.agentTarget
                    && $0.domBindingEpoch == scope.domBindingEpoch
            }),
            canonicalStore.domRoot(in: scope) != nil
        else {
            return false
        }
        return true
    }

    func invalidateStaleDOMCSSOperations(
        applying transaction: WebInspectorCanonicalModelTransaction
    ) {
        let resourceInvalidations =
            (transaction.DOM?.resourceInvalidations ?? [])
            .union(transaction.CSS?.resourceInvalidations ?? [])
        for operationID in domCSSCommandOperations.keys.sorted() {
            guard let operation = domCSSCommandOperations[operationID],
                !operation.isRetired
            else {
                continue
            }
            let error: WebInspectorDOMCSSCommandError?
            if case let .cssResource(lease) = operation.route.validation,
                resourceInvalidations.contains(where: {
                    canonicalStore.resourceInvalidation(
                        $0,
                        affects: lease.nodeID
                    )
                })
            {
                error = .staleCascade
            } else if case let .nodeRead(nodeID) = operation.route.validation,
                resourceInvalidations.contains(where: {
                    canonicalStore.resourceInvalidation(
                        $0,
                        affects: nodeID
                    )
                })
            {
                error = .staleNode
            } else {
                error = domCSSCompletionError(for: operation.route)
            }
            guard let error else {
                continue
            }
            retireDOMCSSCommand(operationID, with: error)
        }
    }

    func retireAllDOMCSSOperations(
        with error: WebInspectorDOMCSSCommandError
    ) {
        for operationID in domCSSCommandOperations.keys.sorted() {
            retireDOMCSSCommand(operationID, with: error)
        }
    }

    func retireDOMCSSCommand(
        _ operationID: UInt64,
        with error: WebInspectorDOMCSSCommandError
    ) {
        guard var operation = domCSSCommandOperations[operationID],
            !operation.isRetired
        else {
            return
        }
        operation.isRetired = true
        domCSSCommandOperations[operationID] = operation
        removeDOMCSSResourceLeaseIndex(
            for: operation,
            operationID: operationID
        )
        precondition(
            operation.completionOnRetirement(error),
            "A DOM/CSS operation was invalidated twice."
        )
        operation.task.cancel()
        performanceCounters.domCSSCommandInvalidationCount += 1
    }

    func removeDOMCSSResourceIndexes(
        for operation: WebInspectorDOMCSSCommandOperation,
        operationID: UInt64
    ) {
        removeDOMCSSResourceLeaseIndex(
            for: operation,
            operationID: operationID
        )
        domCSSResourceCompletions[operationID] = nil
    }

    func removeDOMCSSResourceLeaseIndex(
        for operation: WebInspectorDOMCSSCommandOperation,
        operationID: UInt64
    ) {
        guard case let .cssResource(lease) = operation.route.validation else {
            return
        }
        if domCSSOperationIDByCSSResourceLease[lease] == operationID {
            domCSSOperationIDByCSSResourceLease[lease] = nil
        }
    }

    func waitForDOMCSSOperationsToFinish() async {
        let tasks = domCSSCommandOperations.values.map(\.task)
        for task in tasks {
            await task.value
        }
        precondition(
            domCSSCommandOperations.isEmpty,
            "Model Container lifecycle completed before DOM/CSS commands quiesced."
        )
        precondition(
            domCSSOperationIDByCSSResourceLease.isEmpty,
            "Model Container lifecycle retained a CSS resource lease index."
        )
        precondition(
            domCSSResourceCompletions.isEmpty,
            "Model Container lifecycle retained CSS resource completions."
        )
    }
}
