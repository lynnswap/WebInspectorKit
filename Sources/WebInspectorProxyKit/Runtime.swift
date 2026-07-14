import Foundation

/// A target-scoped handle for Web Inspector Runtime commands and events.
public struct Runtime: Sendable, WebInspectorEventDomainHandle {
    package static let eventDecoder = RuntimeWireCoding.eventDecoder
    package static let eventCapability = RuntimeWireCoding.capability

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    /// Runs an operation with an atomically registered Runtime event scope.
    public func withEvents<Output>(
        buffering: WebInspectorEventBufferingPolicy = .bounded(256),
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<Runtime.Event>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        try await _withEvents(
            buffering: buffering,
            isolation: isolation,
            operation
        )
    }

    /// Evaluates a JavaScript expression in an execution context.
    public func evaluate(
        _ expression: String,
        in context: ExecutionContext.ID? = nil,
        objectGroup: ObjectGroup? = nil
    ) async throws -> EvaluationResult {
        try await endpoint.dispatch(RuntimeWireCoding.evaluate(
            expression: expression,
            context: context,
            objectGroup: objectGroup
        ))
    }

    /// Returns property descriptors for a remote object.
    public func properties(
        of object: RemoteObject.ID,
        ownProperties: Bool = true
    ) async throws -> [PropertyDescriptor] {
        try await endpoint.dispatch(RuntimeWireCoding.properties(
            object: object,
            ownProperties: ownProperties
        ))
    }

    /// Returns a compact preview for a remote object.
    public func preview(of object: RemoteObject.ID) async throws -> ObjectPreview {
        try await endpoint.dispatch(RuntimeWireCoding.preview(object))
    }

    /// Returns entries for an array-like, map-like, or set-like remote object.
    public func collectionEntries(of object: RemoteObject.ID) async throws -> [CollectionEntry] {
        try await endpoint.dispatch(RuntimeWireCoding.collectionEntries(object))
    }

    /// Releases one remote object handle.
    public func releaseObject(_ id: RemoteObject.ID) async throws {
        try await endpoint.dispatch(RuntimeWireCoding.releaseObject(id))
    }

    /// Releases all remote object handles in an object group.
    public func releaseObjectGroup(_ group: ObjectGroup) async throws {
        try await endpoint.dispatch(RuntimeWireCoding.releaseObjectGroup(group))
    }

    /// A JavaScript value or object handle owned by WebKit.
    public struct RemoteObject: Sendable {
        /// Stable identity for a remote object handle.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// The backend handle for object values, if the value can be retained.
        public let id: ID?

        /// The primary JavaScript value kind.
        public let kind: Kind

        /// WebKit's more specific object subtype, if any.
        public let subtype: Subtype?

        /// The JavaScript class name, if known.
        public let className: String?

        /// A display description supplied by WebKit.
        public let description: String?

        /// The inline JSON value for primitive values.
        public let value: JSONValue?

        /// The collection size reported by WebKit.
        public let size: Int?

        /// A compact preview for the value, if included in the payload.
        public let preview: ObjectPreview?

        /// Creates a remote object payload.
        public init(
            id: ID?,
            kind: Kind,
            subtype: Subtype? = nil,
            className: String? = nil,
            description: String? = nil,
            value: JSONValue? = nil,
            size: Int? = nil,
            preview: ObjectPreview? = nil
        ) {
            self.id = id
            self.kind = kind
            self.subtype = subtype
            self.className = className
            self.description = description
            self.value = value
            self.size = size
            self.preview = preview
        }
    }

    /// Primary Runtime value kind.
    public enum Kind: Hashable, Sendable {
        /// A JavaScript object.
        case object

        /// A JavaScript function.
        case function

        /// A string primitive.
        case string

        /// A number primitive.
        case number

        /// A Boolean primitive.
        case boolean

        /// A symbol primitive.
        case symbol

        /// A bigint primitive.
        case bigint

        /// The JavaScript `undefined` value.
        case undefined

        /// The JavaScript `null` value.
        case null

        /// An array object.
        case array

        /// An error object.
        case error

        /// A value kind that is not modeled by this package.
        case other(String)
    }

    /// WebKit's object subtype value.
    public struct Subtype: RawRepresentable, Hashable, Sendable {
        /// The raw protocol subtype.
        public let rawValue: String

        /// Creates a subtype from its raw protocol value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// JSON-compatible primitive value carried inline by Runtime payloads.
    public indirect enum JSONValue: Equatable, Sendable {
        /// A string value.
        case string(String)

        /// A number value.
        case number(Double)

        /// A Boolean value.
        case bool(Bool)

        /// A null value.
        case null

        /// An array value.
        case array([JSONValue])

        /// An object value.
        case object([String: JSONValue])
    }

    /// Result of evaluating a JavaScript expression.
    public struct EvaluationResult: Sendable {
        /// The evaluated value.
        public let object: RemoteObject

        /// A Boolean value indicating whether evaluation threw an exception.
        public let wasThrown: Bool

        /// WebKit's saved result index, if one was assigned.
        public let savedResultIndex: Int?

        /// Creates an evaluation result.
        public init(object: RemoteObject, wasThrown: Bool = false, savedResultIndex: Int? = nil) {
            self.object = object
            self.wasThrown = wasThrown
            self.savedResultIndex = savedResultIndex
        }
    }

    /// A JavaScript execution context for a frame or worker.
    public struct ExecutionContext: Identifiable, Sendable {
        /// Stable identity for an execution context.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// The backend identity for the context.
        public let id: ID

        /// The display name for the context.
        public let name: String

        /// The frame associated with the context, if any.
        public let frameID: FrameID?

        /// The context kind reported by WebKit.
        public let kind: ContextKind

        /// Creates an execution context payload.
        public init(id: ID, name: String, frameID: FrameID? = nil, kind: ContextKind) {
            self.id = id
            self.name = name
            self.frameID = frameID
            self.kind = kind
        }
    }

    /// Kind of Runtime execution context.
    public enum ContextKind: Hashable, Sendable {
        /// A normal page execution context.
        case normal

        /// A user-created context.
        case user

        /// An internal WebKit context.
        case internalContext

        /// A context kind that is not modeled by this package.
        case other(String)
    }

    /// Runtime object group used for retaining and releasing remote objects.
    public enum ObjectGroup: Hashable, Sendable {
        /// The console object group.
        case console

        /// A custom object group.
        case other(String)
    }

    /// A property descriptor for a remote object.
    public struct PropertyDescriptor: Sendable {
        /// The property name.
        public let name: String

        /// The property value, if present.
        public let value: RemoteObject?

        /// A Boolean value indicating whether the property is writable.
        public let writable: Bool?

        /// The getter function object, if present.
        public let get: RemoteObject?

        /// The setter function object, if present.
        public let set: RemoteObject?

        /// A Boolean value indicating whether reading the property threw.
        public let wasThrown: Bool?

        /// A Boolean value indicating whether the property is configurable.
        public let configurable: Bool?

        /// A Boolean value indicating whether the property is enumerable.
        public let enumerable: Bool?

        /// A Boolean value indicating whether the property belongs directly to the object.
        public let isOwn: Bool?

        /// The symbol that names the property, if this is a symbol property.
        public let symbol: RemoteObject?

        /// A Boolean value indicating whether the property is private.
        public let isPrivate: Bool?

        /// A Boolean value indicating whether the property is backed by a native getter.
        public let nativeGetter: Bool?

        /// Creates a property descriptor.
        public init(
            name: String,
            value: RemoteObject? = nil,
            writable: Bool? = nil,
            get: RemoteObject? = nil,
            set: RemoteObject? = nil,
            wasThrown: Bool? = nil,
            configurable: Bool? = nil,
            enumerable: Bool? = nil,
            isOwn: Bool? = nil,
            symbol: RemoteObject? = nil,
            isPrivate: Bool? = nil,
            nativeGetter: Bool? = nil
        ) {
            self.name = name
            self.value = value
            self.writable = writable
            self.get = get
            self.set = set
            self.wasThrown = wasThrown
            self.configurable = configurable
            self.enumerable = enumerable
            self.isOwn = isOwn
            self.symbol = symbol
            self.isPrivate = isPrivate
            self.nativeGetter = nativeGetter
        }
    }

    /// A compact, display-oriented preview of a remote object.
    public struct ObjectPreview: Sendable {
        /// The value kind represented by the preview.
        public let kind: Kind?

        /// The object subtype represented by the preview.
        public let subtype: Subtype?

        /// A display description supplied by WebKit.
        public let description: String?

        /// A Boolean value indicating whether the preview is complete.
        public let lossless: Bool

        /// A Boolean value indicating whether WebKit omitted some preview entries.
        public let overflow: Bool

        /// Property previews included in the object preview.
        public let properties: [PropertyPreview]

        /// Collection entry previews included in the object preview.
        public let entries: [EntryPreview]

        /// The collection size represented by the preview.
        public let size: Int?

        /// Creates an object preview.
        public init(
            kind: Kind? = nil,
            subtype: Subtype? = nil,
            description: String? = nil,
            lossless: Bool = false,
            overflow: Bool = false,
            properties: [PropertyPreview] = [],
            entries: [EntryPreview] = [],
            size: Int? = nil
        ) {
            self.kind = kind
            self.subtype = subtype
            self.description = description
            self.lossless = lossless
            self.overflow = overflow
            self.properties = properties
            self.entries = entries
            self.size = size
        }
    }

    /// A compact preview for one object property.
    public struct PropertyPreview: Sendable {
        /// The property name.
        public let name: String

        /// The property value text.
        public let value: String?

        /// Creates a property preview.
        public init(name: String, value: String? = nil) {
            self.name = name
            self.value = value
        }
    }

    /// A compact preview for one collection entry.
    public struct EntryPreview: Sendable {
        /// The entry key text.
        public let key: String?

        /// The entry value text.
        public let value: String?

        /// Creates an entry preview.
        public init(key: String? = nil, value: String? = nil) {
            self.key = key
            self.value = value
        }
    }

    /// A collection entry returned for a remote collection object.
    public struct CollectionEntry: Sendable {
        /// The entry key object, if the collection has keys.
        public let key: RemoteObject?

        /// The entry value object.
        public let value: RemoteObject

        /// Creates a collection entry.
        public init(key: RemoteObject? = nil, value: RemoteObject) {
            self.key = key
            self.value = value
        }
    }

    /// Events emitted by the Runtime domain.
    public enum Event: Sendable {
        /// A new execution context was created.
        case executionContextCreated(ExecutionContext)

        /// An execution context was destroyed.
        case executionContextDestroyed(ExecutionContext.ID)

        /// Execution contexts were cleared for this event scope.
        case executionContextsCleared

        /// An event that is not modeled by this package.
        case unknown(RawEvent)
    }

}

package extension Runtime.RemoteObject.ID {
    private static var targetScopeSeparator: Character { "\u{1E}" }

    init(_ rawValue: String, scopedToTargetRawValue targetRawValue: String) {
        self.init("\(targetRawValue)\(Self.targetScopeSeparator)\(rawValue)")
    }

    var targetScopeRawValue: String? {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        return String(parts[0])
    }

    var unscopedRawValue: String {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return rawValue
        }
        return String(parts[1])
    }
}

package extension Runtime.ExecutionContext.ID {
    private static var targetScopeSeparator: Character { "\u{1E}" }

    init(_ rawValue: String, scopedToTargetRawValue targetRawValue: String) {
        self.init("\(targetRawValue)\(Self.targetScopeSeparator)\(rawValue)")
    }

    var targetScopeRawValue: String? {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        return String(parts[0])
    }

    var unscopedRawValue: String {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return rawValue
        }
        return String(parts[1])
    }
}
