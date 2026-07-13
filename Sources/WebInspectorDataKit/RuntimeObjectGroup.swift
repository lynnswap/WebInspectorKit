import WebInspectorProxyKit

/// Preserves both a failed scoped operation and its independent cleanup error.
public struct WebInspectorRuntimeScopeError: Error {
    public let operationError: any Error
    public let cleanupError: any Error

    public init(operationError: any Error, cleanupError: any Error) {
        self.operationError = operationError
        self.cleanupError = cleanupError
    }
}

public typealias RuntimeProperty = RuntimeObject.Property
public typealias RuntimeObjectPreview = Runtime.ObjectPreview

/// A context-local owner for one Core-owned Runtime object graph.
///
/// The Core retains every wire identifier and command authority. This object
/// materializes graph resources into actor-confined Observable objects and is
/// the sole close authority exposed to callers.
public final class RuntimeObjectGroup {
    package weak var modelContext: WebInspectorModelContext?
    package let token: WebInspectorRuntimeObjectGraphToken
    package let boundContextID: RuntimeContext.ID?
    package var objectsByID: [
        WebInspectorRuntimeObjectResourceID: RuntimeObject
    ] = [:]
    public private(set) var isClosed = false

    package init(
        modelContext: WebInspectorModelContext,
        token: WebInspectorRuntimeObjectGraphToken,
        boundContextID: RuntimeContext.ID?
    ) {
        self.modelContext = modelContext
        self.token = token
        self.boundContextID = boundContextID
    }

    public nonisolated(nonsending) func evaluate(
        _ expression: String,
        in context: RuntimeContext? = nil
    ) async throws -> RuntimeEvaluation {
        guard let modelContext else {
            throw WebInspectorModelError.staleModel
        }
        modelContext.preconditionOwnerIsolation()
        guard !isClosed else {
            throw WebInspectorModelError.staleModel
        }
        return try await modelContext.evaluate(
            expression,
            in: context,
            objectGroup: self
        )
    }

    public nonisolated(nonsending) func properties(
        of object: RuntimeObject,
        ownProperties: Bool = true
    ) async throws -> [RuntimeProperty] {
        guard let modelContext else {
            throw WebInspectorModelError.staleModel
        }
        modelContext.preconditionOwnerIsolation()
        guard !isClosed else {
            throw WebInspectorModelError.staleModel
        }
        return try await modelContext.properties(
            of: object,
            ownProperties: ownProperties,
            objectGroup: self
        )
    }

    public nonisolated(nonsending) func preview(
        of object: RuntimeObject
    ) async throws -> RuntimeObjectPreview {
        guard let modelContext else {
            throw WebInspectorModelError.staleModel
        }
        modelContext.preconditionOwnerIsolation()
        guard !isClosed else {
            throw WebInspectorModelError.staleModel
        }
        return try await modelContext.preview(of: object, objectGroup: self)
    }

    public nonisolated(nonsending) func collectionEntries(
        of object: RuntimeObject
    ) async throws -> [RuntimeObject.Entry] {
        guard let modelContext else {
            throw WebInspectorModelError.staleModel
        }
        modelContext.preconditionOwnerIsolation()
        guard !isClosed else {
            throw WebInspectorModelError.staleModel
        }
        return try await modelContext.collectionEntries(
            of: object,
            objectGroup: self
        )
    }

    public nonisolated(nonsending) func close() async throws {
        guard let modelContext else {
            throw WebInspectorModelError.staleModel
        }
        modelContext.preconditionOwnerIsolation()
        guard !isClosed else {
            return
        }
        try await modelContext.close(objectGroup: self)
    }

    package func resourceID(
        for object: RuntimeObject
    ) throws -> WebInspectorRuntimeObjectResourceID {
        guard !isClosed,
            case let .graphResource(id) = object.id.storage,
            id.graph == token,
            objectsByID[id] === object
        else {
            throw WebInspectorModelError.staleModel
        }
        return id
    }

    package func materialize(
        _ resource: WebInspectorRuntimeObjectResource
    ) -> RuntimeObject {
        precondition(
            !isClosed && resource.id.graph == token,
            "A Runtime resource must be materialized by its open graph owner."
        )
        if let object = objectsByID[resource.id] {
            return object
        }
        let object = RuntimeObject(graphResource: resource)
        objectsByID[resource.id] = object
        return object
    }

    package func finishClose() {
        guard !isClosed else {
            return
        }
        isClosed = true
        for object in objectsByID.values {
            object.invalidateCanonicalResource()
        }
        objectsByID.removeAll(keepingCapacity: false)
        modelContext = nil
    }
}
