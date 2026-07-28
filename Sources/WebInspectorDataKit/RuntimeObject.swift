import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for a Runtime remote object.
@Observable
public final class RuntimeObject: WebInspectorPersistentModel {
    struct Authority: Equatable {
        struct Context: Equatable {
            var id: RuntimeContext.ID
            var identity: ObjectIdentifier
        }

        var pageGeneration: Int
        var targetID: WebInspectorTarget.ID
        var targetRevision: UInt64
        var context: Context?
        var frameID: FrameID?

        func merging(_ other: Authority) -> Authority? {
            guard pageGeneration == other.pageGeneration,
                  targetID == other.targetID,
                  targetRevision == other.targetRevision else {
                return nil
            }

            let mergedContext: Context?
            switch (context, other.context) {
            case let (lhs?, rhs?) where lhs != rhs:
                return nil
            case let (lhs?, _):
                mergedContext = lhs
            case let (_, rhs?):
                mergedContext = rhs
            case (nil, nil):
                mergedContext = nil
            }

            let mergedFrameID: FrameID?
            switch (frameID, other.frameID) {
            case let (lhs?, rhs?) where lhs != rhs:
                return nil
            case let (lhs?, _):
                mergedFrameID = lhs
            case let (_, rhs?):
                mergedFrameID = rhs
            case (nil, nil):
                mergedFrameID = nil
            }

            return Authority(
                pageGeneration: pageGeneration,
                targetID: targetID,
                targetRevision: targetRevision,
                context: mergedContext,
                frameID: mergedFrameID
            )
        }
    }

    /// Stable identity for a runtime object within a context.
    public struct ID: Hashable, Sendable {
        enum Storage: Hashable, Sendable {
            case remote(Runtime.RemoteObject.ID)
            case synthetic(Int)
        }

        let storage: Storage

        init(remote id: Runtime.RemoteObject.ID) {
            storage = .remote(id)
        }

        init(synthetic ordinal: Int) {
            storage = .synthetic(ordinal)
        }
    }

    /// Display model for a property returned from a ``RuntimeObject``.
    public struct Property {
        /// The property name.
        public let name: String

        /// The primitive property value text, if one is available.
        public let value: String?

        /// The remote object value, if the property value has object identity.
        public let object: RuntimeObject?

        /// Creates a runtime object property.
        public init(name: String, value: String? = nil, object: RuntimeObject? = nil) {
            self.name = name
            self.value = value
            self.object = object
        }
    }

    /// Display model for a collection entry returned from a ``RuntimeObject``.
    public struct Entry {
        /// The entry key object, if present.
        public let key: RuntimeObject?

        /// The entry value object, if present.
        public let value: RuntimeObject?

        /// Creates a runtime collection entry.
        public init(key: RuntimeObject? = nil, value: RuntimeObject? = nil) {
            self.key = key
            self.value = value
        }
    }

    /// The stable runtime object identity.
    public let id: ID

    /// The primary JavaScript value kind.
    public private(set) var kind: Runtime.Kind

    /// WebKit's more specific object subtype, if any.
    public private(set) var subtype: Runtime.Subtype?

    /// The JavaScript class name, if known.
    public private(set) var className: String?

    /// The inline JSON value for primitive values.
    public private(set) var value: Runtime.JSONValue?

    /// A display description supplied by WebKit.
    public private(set) var description: String?

    /// The collection size reported by WebKit.
    public private(set) var size: Int?

    /// A compact preview for the value, if included in the payload.
    public private(set) var preview: Runtime.ObjectPreview?

    @ObservationIgnored weak var modelContext: WebInspectorContext?
    var proxyID: Runtime.RemoteObject.ID?
    @ObservationIgnored var authority: Authority

    /// A Boolean value indicating whether this object has a live remote handle.
    public var canRequestProperties: Bool {
        proxyID != nil && modelContext != nil
    }

    init(
        id: ID,
        remoteObject: Runtime.RemoteObject,
        authority: Authority,
        modelContext: WebInspectorContext
    ) {
        self.id = id
        kind = remoteObject.kind
        subtype = remoteObject.subtype
        className = remoteObject.className
        value = remoteObject.value
        description = remoteObject.description
        size = remoteObject.size
        preview = remoteObject.preview
        proxyID = remoteObject.id
        self.authority = authority
        self.modelContext = modelContext
    }

    /// Requests own property values for this object.
    public func properties(isolation: isolated (any Actor) = #isolation) async throws -> [Property] {
        guard let modelContext else {
            throw WebInspectorProxyError.disconnected("RuntimeObject is not registered in this WebInspectorContext.")
        }
        guard canRequestProperties else {
            return []
        }
        return try await modelContext.properties(for: self, isolation: isolation)
    }

    /// Requests collection entries for this object.
    public func collectionEntries(isolation: isolated (any Actor) = #isolation) async throws -> [Entry] {
        guard let modelContext else {
            throw WebInspectorProxyError.disconnected("RuntimeObject is not registered in this WebInspectorContext.")
        }
        guard canRequestProperties else {
            return []
        }
        return try await modelContext.collectionEntries(for: self, isolation: isolation)
    }

    func invalidateRemoteHandle() {
        proxyID = nil
        modelContext = nil
    }

    func update(from remoteObject: Runtime.RemoteObject) {
        kind = remoteObject.kind
        subtype = remoteObject.subtype
        className = remoteObject.className
        value = remoteObject.value
        description = remoteObject.description
        size = remoteObject.size
        preview = remoteObject.preview
        proxyID = remoteObject.id
    }
}

/// Result of evaluating JavaScript through DataKit.
public struct RuntimeEvaluation {
    /// The evaluated value.
    public let object: RuntimeObject

    /// A Boolean value indicating whether evaluation threw an exception.
    public let isException: Bool

    /// Creates a runtime evaluation result.
    public init(object: RuntimeObject, isException: Bool) {
        self.object = object
        self.isException = isException
    }
}
