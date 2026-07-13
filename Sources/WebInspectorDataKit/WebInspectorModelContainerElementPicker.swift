import WebInspectorProxyKit

package enum WebInspectorElementPickerError: Error, Equatable, Sendable {
    case closed
    case detached
    case domainNotConfigured
    case operationAlreadyActive
    case staleDocument
    case nodeNotFound
    case feedFailure(WebInspectorModelContainer.Failure)
    case proxy(WebInspectorProxyError)
    case authorization(ConnectionModelCommandError)
    case invalidReply(String)
}

struct WebInspectorElementPickerOperationState: Sendable {
    enum Phase: Sendable {
        case waitingForSelection
        case resolving(Task<Void, Never>)
        case releasing
    }

    let id: UInt64
    let resourceID: UInt64
    let generation: WebInspectorContainerAttachmentGeneration
    let lease: ConnectionModelElementPickerLease
    let completion: ReplyPromise<WebInspectorDOMNodeIdentityStorage?>
    let cleanupCompletion: ReplyPromise<Void>
    var phase: Phase
}

package extension WebInspectorModelContainerCore {
    /// Runs one UI-owned element-picker operation through the Container-owned
    /// feed lease and returns the selected canonical node identity.
    func pickDOMNode() async throws -> WebInspectorDOMNodeIdentityStorage? {
        try Task.checkCancellation()
        guard !isConnectionCloseRequested else {
            throw WebInspectorElementPickerError.closed
        }
        guard configuredDomains.contains(.dom) else {
            throw WebInspectorElementPickerError.domainNotConfigured
        }
        guard let resource = activeAttachment else {
            throw WebInspectorElementPickerError.detached
        }
        guard elementPickerOperation == nil else {
            throw WebInspectorElementPickerError.operationAlreadyActive
        }
        precondition(
            nextElementPickerOperationID < UInt64.max,
            "Model Container Core exhausted element-picker operation identifiers."
        )
        nextElementPickerOperationID += 1
        let operationID = nextElementPickerOperationID
        let completion = ReplyPromise<WebInspectorDOMNodeIdentityStorage?>()
        let lease = resource.feed.makeElementPickerLease()
        elementPickerOperation = WebInspectorElementPickerOperationState(
            id: operationID,
            resourceID: resource.id,
            generation: resource.generation,
            lease: lease,
            completion: completion,
            cleanupCompletion: ReplyPromise(),
            phase: .waitingForSelection
        )

        do {
            try await lease.acquire()
        } catch {
            if let operation = elementPickerOperation,
                operation.id == operationID
            {
                elementPickerOperation = nil
                if case let .resolving(task) = operation.phase {
                    task.cancel()
                }
            }
            throw Self.mapElementPickerError(error)
        }

        guard activeAttachment?.id == resource.id,
            activeAttachment?.generation == resource.generation,
            !isConnectionCloseRequested
        else {
            _ = try? await webInspectorRunIgnoringCancellation {
                try await lease.release()
            }
            throw isConnectionCloseRequested
                ? WebInspectorElementPickerError.closed
                : WebInspectorElementPickerError.detached
        }

        do {
            return try await completion.value()
        } catch is CancellationError {
            do {
                try await cancelElementPickerOperation(operationID)
            } catch {
                throw WebInspectorScopeError(
                    operationError: CancellationError(),
                    cleanupError: error
                )
            }
            throw CancellationError()
        }
    }

    func applyCanonicalElementPickerActions(
        _ actions: [WebInspectorCanonicalModelAction],
        resourceID: UInt64,
        generation: WebInspectorContainerAttachmentGeneration
    ) {
        guard !actions.isEmpty else {
            return
        }
        for action in actions {
            guard case let .inspectRemoteObject(scope, objectID) = action,
                var operation = elementPickerOperation,
                operation.resourceID == resourceID,
                operation.generation == generation,
                case .waitingForSelection = operation.phase
            else {
                continue
            }
            let operationID = operation.id
            let resolutionTask = Task.detached(
                priority: .userInitiated
            ) { [weak self] in
                guard let self else {
                    return
                }
                let result: Result<
                    WebInspectorDOMNodeIdentityStorage?,
                    any Error
                >
                do {
                    result = .success(
                        try await self.resolveElementPickerAction(
                            scope: scope,
                            objectID: objectID
                        )
                    )
                } catch {
                    result = .failure(error)
                }
                await self.finishElementPickerOperation(
                    operationID,
                    result: result
                )
            }
            operation.phase = .resolving(resolutionTask)
            elementPickerOperation = operation
        }
    }

    func retireElementPickerOperation(with error: any Error) {
        guard let operation = elementPickerOperation else {
            return
        }
        elementPickerOperation = nil
        if case let .resolving(task) = operation.phase {
            task.cancel()
        }
        precondition(
            operation.completion.fulfill(.failure(error)),
            "A live element-picker operation completed before its Core owner retired it."
        )
    }
}

private extension WebInspectorModelContainerCore {
    func resolveElementPickerAction(
        scope: ModelEventScope,
        objectID: Runtime.RemoteObject.ID?
    ) async throws -> WebInspectorDOMNodeIdentityStorage? {
        guard let objectID else {
            return nil
        }
        guard let resource = activeAttachment,
            let documentScope = WebInspectorDOMDocumentScopeStorage(
                storeID: storeID,
                attachmentGeneration: resource.generation,
                eventScope: WebInspectorCanonicalDOMEventScope(
                    modelScope: scope
                )
            )
        else {
            throw WebInspectorElementPickerError.staleDocument
        }
        let route = try domDocumentCommandRoute(
            for: documentScope,
            completionValidation: .document(documentScope)
        )
        let completion: ReplyPromise<DOM.Node.ID> = startDOMCSSCommand(
            route: route
        ) { target in
            try await target.dom.requestNode(forRemoteObject: objectID)
        }
        let rawNodeID = try await completion.value()
        guard let nodeID = try canonicalStore.domNodeID(
            for: rawNodeID,
            in: scope
        ) else {
            throw WebInspectorElementPickerError.nodeNotFound
        }
        return nodeID
    }

    func finishElementPickerOperation(
        _ operationID: UInt64,
        result: Result<WebInspectorDOMNodeIdentityStorage?, any Error>
    ) async {
        guard var operation = elementPickerOperation,
            operation.id == operationID
        else {
            return
        }
        guard case .resolving = operation.phase else {
            return
        }
        operation.phase = .releasing
        elementPickerOperation = operation
        let lease = operation.lease
        let releaseResult: Result<Void, any Error>
        do {
            try await webInspectorRunIgnoringCancellation {
                try await lease.release()
            }
            releaseResult = .success(())
        } catch {
            releaseResult = .failure(Self.mapElementPickerError(error))
        }

        let terminal: Result<WebInspectorDOMNodeIdentityStorage?, any Error>
        switch (result, releaseResult) {
        case let (.success(nodeID), .success):
            terminal = .success(nodeID)
        case let (.failure(operationError), .success):
            terminal = .failure(Self.mapElementPickerError(operationError))
        case let (.success, .failure(cleanupError)):
            terminal = .failure(Self.mapElementPickerError(cleanupError))
        case let (.failure(operationError), .failure(cleanupError)):
            terminal = .failure(WebInspectorScopeError(
                operationError: Self.mapElementPickerError(operationError),
                cleanupError: Self.mapElementPickerError(cleanupError)
            ))
        }
        let remainedCurrent = elementPickerOperation?.id == operationID
        if remainedCurrent {
            elementPickerOperation = nil
        }
        operation.cleanupCompletion.fulfill(releaseResult)
        if remainedCurrent {
            precondition(
                operation.completion.fulfill(terminal),
                "A current element-picker operation completed twice."
            )
        }
    }

    func cancelElementPickerOperation(_ operationID: UInt64) async throws {
        guard var operation = elementPickerOperation,
            operation.id == operationID
        else {
            return
        }
        if case .releasing = operation.phase {
            return try await operation.cleanupCompletion
                .valueIgnoringCancellation()
        }
        if case let .resolving(task) = operation.phase {
            task.cancel()
        }
        operation.phase = .releasing
        elementPickerOperation = operation

        let lease = operation.lease
        let releaseResult: Result<Void, any Error>
        do {
            try await webInspectorRunIgnoringCancellation {
                try await lease.release()
            }
            releaseResult = .success(())
        } catch {
            releaseResult = .failure(Self.mapElementPickerError(error))
        }

        let remainedCurrent = elementPickerOperation?.id == operationID
        if remainedCurrent {
            elementPickerOperation = nil
        }
        operation.cleanupCompletion.fulfill(releaseResult)
        switch releaseResult {
        case .success:
            if remainedCurrent {
                _ = operation.completion.fulfill(
                    .failure(CancellationError())
                )
            }
        case let .failure(cleanupError):
            if remainedCurrent {
                _ = operation.completion.fulfill(.failure(cleanupError))
            }
            throw cleanupError
        }
    }

    nonisolated static func mapElementPickerError(
        _ error: any Error
    ) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? WebInspectorElementPickerError {
            return error
        }
        if let error = error as? WebInspectorDOMCSSCommandError {
            switch error {
            case .closed:
                return WebInspectorElementPickerError.closed
            case .detached:
                return WebInspectorElementPickerError.detached
            case .domainNotConfigured:
                return WebInspectorElementPickerError.domainNotConfigured
            case .staleDocument, .staleNode, .staleCascade:
                return WebInspectorElementPickerError.staleDocument
            case .nodeNotFound:
                return WebInspectorElementPickerError.nodeNotFound
            case let .proxy(error):
                return WebInspectorElementPickerError.proxy(error)
            case let .authorization(error):
                return WebInspectorElementPickerError.authorization(error)
            case .foreignStore,
                .styleSheetNotFound,
                .agentTargetUnavailable,
                .identityRouteMismatch,
                .staleStyleSheet,
                .invalidReply:
                return WebInspectorElementPickerError.invalidReply(
                    String(reflecting: error)
                )
            }
        }
        if let error = error as? WebInspectorProxyError {
            return WebInspectorElementPickerError.proxy(error)
        }
        if let error = error as? ConnectionModelCommandError {
            return WebInspectorElementPickerError.authorization(error)
        }
        return WebInspectorElementPickerError.invalidReply(
            String(reflecting: error)
        )
    }
}
