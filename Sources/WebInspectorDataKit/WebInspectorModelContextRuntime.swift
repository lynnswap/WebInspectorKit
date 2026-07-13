import WebInspectorProxyKit

extension WebInspectorModelContext {
    /// Runs an operation with one uniquely named Runtime object group.
    public nonisolated(nonsending) func withRuntimeObjectGroup<Output>(
        named: String? = nil,
        boundTo context: RuntimeContext? = nil,
        _ operation: nonisolated(nonsending) (RuntimeObjectGroup) async throws -> Output
    ) async throws -> Output {
        preconditionOwnerIsolation()
        let objectGroup = try await makeRuntimeObjectGroup(
            named: named,
            boundTo: context
        )
        let operationResult: Result<Output, any Error>
        do {
            operationResult = .success(try await operation(objectGroup))
        } catch {
            operationResult = .failure(error)
        }

        switch operationResult {
        case let .success(output):
            try await objectGroup.close()
            return output
        case let .failure(operationError):
            do {
                try await objectGroup.close()
            } catch {
                throw WebInspectorRuntimeScopeError(
                    operationError: operationError,
                    cleanupError: error
                )
            }
            throw operationError
        }
    }

    private nonisolated(nonsending) func makeRuntimeObjectGroup(
        named name: String?,
        boundTo context: RuntimeContext?
    ) async throws -> RuntimeObjectGroup {
        preconditionOwnerIsolation()
        try requireConfigured(.runtime)
        let contextStorage: CanonicalRuntimeContextIDStorage?
        if let context {
            guard context.modelContext === self,
                registeredModel(for: context.id) === context
            else {
                throw WebInspectorModelError.staleModel
            }
            contextStorage = context.id.canonicalStorage
        } else {
            contextStorage = nil
        }
        let claim: WebInspectorRuntimeObjectGroupClaim
        do {
            claim = try await container.core.createRuntimeObjectGroup(
                named: name ?? "group",
                boundTo: contextStorage
            )
        } catch {
            throw Self.publicRuntimeError(error)
        }
        return RuntimeObjectGroup(
            modelContext: self,
            token: claim.token,
            boundContextID: context?.id
        )
    }

    package nonisolated(nonsending) func evaluate(
        _ expression: String,
        in context: RuntimeContext?,
        objectGroup: RuntimeObjectGroup
    ) async throws -> RuntimeEvaluation {
        try validate(objectGroup)
        if let context, objectGroup.boundContextID != context.id {
            throw WebInspectorModelError.staleModel
        }
        let result: WebInspectorRuntimeEvaluationResource
        do {
            result = try await container.core.evaluateRuntimeExpression(
                expression,
                in: objectGroup.token
            )
        } catch {
            throw Self.publicRuntimeError(error)
        }
        try validate(objectGroup)
        return RuntimeEvaluation(
            object: objectGroup.materialize(result.object),
            isException: result.wasThrown
        )
    }

    package nonisolated(nonsending) func properties(
        of object: RuntimeObject,
        ownProperties: Bool,
        objectGroup: RuntimeObjectGroup
    ) async throws -> [RuntimeProperty] {
        try validate(objectGroup)
        let objectID = try objectGroup.resourceID(for: object)
        let resources: [WebInspectorRuntimePropertyResource]
        do {
            resources = try await container.core.runtimeProperties(
                of: objectID,
                ownProperties: ownProperties
            )
        } catch {
            throw Self.publicRuntimeError(error)
        }
        try validate(objectGroup)
        return resources.map { resource in
            RuntimeProperty(
                name: resource.name,
                value: resource.value.flatMap(Self.runtimeValueText),
                object: resource.value.flatMap { value in
                    value.payload.rawObjectID == nil
                        ? nil
                        : objectGroup.materialize(value)
                }
            )
        }
    }

    package nonisolated(nonsending) func preview(
        of object: RuntimeObject,
        objectGroup: RuntimeObjectGroup
    ) async throws -> RuntimeObjectPreview {
        try validate(objectGroup)
        let objectID = try objectGroup.resourceID(for: object)
        let preview: CanonicalRuntimeObjectPreview
        do {
            preview = try await container.core.runtimePreview(of: objectID)
        } catch {
            throw Self.publicRuntimeError(error)
        }
        try validate(objectGroup)
        return preview.objectPreview
    }

    package nonisolated(nonsending) func collectionEntries(
        of object: RuntimeObject,
        objectGroup: RuntimeObjectGroup
    ) async throws -> [RuntimeObject.Entry] {
        try validate(objectGroup)
        let objectID = try objectGroup.resourceID(for: object)
        let resources: [WebInspectorRuntimeCollectionEntryResource]
        do {
            resources = try await container.core.runtimeCollectionEntries(
                of: objectID
            )
        } catch {
            throw Self.publicRuntimeError(error)
        }
        try validate(objectGroup)
        return resources.map { resource in
            RuntimeObject.Entry(
                key: resource.key.map(objectGroup.materialize),
                value: objectGroup.materialize(resource.value)
            )
        }
    }

    package nonisolated(nonsending) func close(
        objectGroup: RuntimeObjectGroup
    ) async throws {
        preconditionOwnerIsolation()
        guard objectGroup.modelContext === self else {
            throw WebInspectorModelError.staleModel
        }
        do {
            try await container.core.closeRuntimeObjectGraph(objectGroup.token)
        } catch WebInspectorRuntimeCommandGatewayError.graphClosed,
            WebInspectorRuntimeCommandGatewayError.graphNotFound,
            WebInspectorRuntimeCommandGatewayError.staleAuthority
        {
            objectGroup.finishClose()
            return
        } catch {
            throw Self.publicRuntimeError(error)
        }
        objectGroup.finishClose()
    }

    private func validate(_ objectGroup: RuntimeObjectGroup) throws {
        preconditionOwnerIsolation()
        guard objectGroup.modelContext === self, !objectGroup.isClosed else {
            throw WebInspectorModelError.staleModel
        }
    }

    private nonisolated static func runtimeValueText(
        _ resource: WebInspectorRuntimeObjectResource
    ) -> String? {
        let payload = resource.payload
        if let description = payload.description {
            return description
        }
        guard let value = payload.value else {
            return nil
        }
        switch value {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return "null"
        case .array, .object:
            return nil
        }
    }

    private nonisolated static func publicRuntimeError(
        _ error: any Error
    ) -> any Error {
        guard let error = error as? WebInspectorRuntimeCommandGatewayError else {
            return error
        }
        switch error {
        case .closed, .graphNotFound, .graphClosed, .staleAuthority,
            .objectNotFound, .objectHasNoRemoteIdentity,
            .runtimeContextNotFound, .consoleMessageNotFound,
            .consoleParameterIndexOutOfBounds:
            return WebInspectorModelError.staleModel
        case .detached, .currentPageUnavailable, .physicalAgentUnavailable:
            return WebInspectorModelError.detached
        case let .domainNotConfigured(domain):
            return WebInspectorModelError.domainNotConfigured(
                publicDomain(domain)
            )
        case .foreignStore:
            return WebInspectorModelError.staleModel
        case let .proxy(error):
            return error
        case let .authorization(error):
            return WebInspectorModelError.commandRejected(
                method: "Runtime",
                message: String(describing: error)
            )
        case .commandResultMismatch, .invalidReply:
            return WebInspectorModelError.commandRejected(
                method: "Runtime",
                message: String(describing: error)
            )
        }
    }

    private nonisolated static func publicDomain(
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
