import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for a Runtime remote object.
@Observable
public final class RuntimeObject: Hashable, Identifiable, SendableMetatype {
    /// Stable identity for a runtime object within a context.
    public struct ID: Hashable, Sendable {
        enum Storage: Hashable, Sendable {
            case legacyRemote(Runtime.RemoteObject.ID)
            case legacySynthetic(Int)
            case consoleParameter(
                messageID: ConsoleMessage.ID,
                parameterIndex: Int
            )
        }

        let storage: Storage

        init(remote id: Runtime.RemoteObject.ID) {
            storage = .legacyRemote(id)
        }

        init(synthetic ordinal: Int) {
            storage = .legacySynthetic(ordinal)
        }

        package init(
            consoleMessageID: ConsoleMessage.ID,
            parameterIndex: Int
        ) {
            precondition(
                consoleMessageID.canonicalStorage != nil,
                "A Console parameter resource requires a canonical message owner."
            )
            precondition(
                parameterIndex >= 0,
                "A Console parameter index cannot be negative."
            )
            storage = .consoleParameter(
                messageID: consoleMessageID,
                parameterIndex: parameterIndex
            )
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

    private var isCanonicalResourceInvalidated: Bool
    private let canonicalResourceHasRemoteIdentity: Bool

    @ObservationIgnored var proxyID: Runtime.RemoteObject.ID?

    /// A Boolean value indicating whether this object has a live remote handle.
    public var canRequestProperties: Bool {
        isCanonicalResourceInvalidated == false
            && (canonicalResourceHasRemoteIdentity || proxyID != nil)
    }

    init(
        id: ID,
        remoteObject: Runtime.RemoteObject
    ) {
        self.id = id
        kind = remoteObject.kind
        subtype = remoteObject.subtype
        className = remoteObject.className
        value = remoteObject.value
        description = remoteObject.description
        size = remoteObject.size
        preview = remoteObject.preview
        isCanonicalResourceInvalidated = false
        canonicalResourceHasRemoteIdentity = false
        proxyID = remoteObject.id
    }

    package init(
        consoleMessageID: ConsoleMessage.ID,
        parameterIndex: Int,
        payload: CanonicalRuntimeRemoteObjectPayload
    ) {
        id = ID(
            consoleMessageID: consoleMessageID,
            parameterIndex: parameterIndex
        )
        kind = payload.kind
        subtype = payload.subtype
        className = payload.className
        value = payload.value
        description = payload.description
        size = payload.size
        preview = payload.preview?.objectPreview
        isCanonicalResourceInvalidated = false
        canonicalResourceHasRemoteIdentity = payload.rawObjectID != nil
        // Canonical command authority is the Console message/index owner in
        // `id`, which the Runtime gateway exchanges for a graph token. The raw
        // WebKit handle stays in the Core-owned canonical seed.
        proxyID = nil
    }

    /// Compares Runtime resources by object identity.
    public nonisolated static func == (lhs: RuntimeObject, rhs: RuntimeObject) -> Bool {
        lhs === rhs
    }

    /// Hashes a Runtime resource by object identity.
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func update(from remoteObject: Runtime.RemoteObject) {
        kind = remoteObject.kind
        subtype = remoteObject.subtype
        className = remoteObject.className
        value = remoteObject.value
        description = remoteObject.description
        size = remoteObject.size
        preview = remoteObject.preview
        isCanonicalResourceInvalidated = false
        proxyID = remoteObject.id
    }

    package func invalidateCanonicalResource() {
        guard case .consoleParameter = id.storage else {
            return
        }
        isCanonicalResourceInvalidated = true
        proxyID = nil
    }
}

private extension CanonicalRuntimeObjectPreview {
    var objectPreview: Runtime.ObjectPreview {
        Runtime.ObjectPreview(
            kind: kind,
            subtype: subtype,
            description: description,
            lossless: lossless,
            overflow: overflow,
            properties: properties.map { preview in
                Runtime.PropertyPreview(
                    name: preview.name,
                    value: preview.value
                )
            },
            entries: entries.map { preview in
                Runtime.EntryPreview(
                    key: preview.key,
                    value: preview.value
                )
            },
            size: size
        )
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
