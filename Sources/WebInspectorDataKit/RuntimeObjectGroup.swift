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

/// An explicit binding-scoped owner of Runtime remote object identities.
public final class RuntimeObjectGroup {
    package struct ID: Hashable {
        package let rawValue: UInt64
    }

    package weak var modelContext: WebInspectorModelContext?
    package let id: ID
    package let target: WebInspectorTarget
    package let wireGroup: Runtime.ObjectGroup
    package let attachmentGeneration: UInt64
    package let pageGeneration: WebInspectorPage.Generation
    public private(set) var isClosed: Bool

    package init(
        modelContext: WebInspectorModelContext,
        id: ID,
        target: WebInspectorTarget,
        wireGroup: Runtime.ObjectGroup,
        attachmentGeneration: UInt64,
        pageGeneration: WebInspectorPage.Generation
    ) {
        self.modelContext = modelContext
        self.id = id
        self.target = target
        self.wireGroup = wireGroup
        self.attachmentGeneration = attachmentGeneration
        self.pageGeneration = pageGeneration
        isClosed = false
    }

    public nonisolated(nonsending) func evaluate(
        _ expression: String,
        in context: RuntimeContext? = nil
    ) async throws -> RuntimeEvaluation {
        guard !isClosed, let modelContext else {
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
        guard !isClosed, let modelContext else {
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
        guard !isClosed, let modelContext else {
            throw WebInspectorModelError.staleModel
        }
        return try await modelContext.preview(of: object, objectGroup: self)
    }

    public nonisolated(nonsending) func close() async throws {
        guard !isClosed else {
            return
        }
        defer {
            isClosed = true
        }
        guard let modelContext else {
            throw WebInspectorModelError.staleModel
        }
        try await modelContext.close(objectGroup: self)
    }
}
