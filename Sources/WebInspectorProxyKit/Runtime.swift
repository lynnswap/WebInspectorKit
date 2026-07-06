import Foundation

public enum Runtime {
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func enable() async throws {
            try await context.dispatchVoid(
                domain: .runtime,
                method: "enable",
                payload: EnablePayload()
            )
        }

        public func disable() async throws {
            try await context.dispatchVoid(
                domain: .runtime,
                method: "disable",
                payload: DisablePayload()
            )
        }

        public func evaluate(
            _ expression: String,
            in context: ExecutionContext.ID? = nil
        ) async throws -> EvaluationResult {
            try await self.context.dispatch(
                domain: .runtime,
                method: "evaluate",
                payload: EvaluatePayload(expression: expression, context: context),
                returning: EvaluationResult.self
            )
        }

        public func properties(
            of object: RemoteObject.ID,
            ownProperties: Bool = true
        ) async throws -> [PropertyDescriptor] {
            try await context.dispatch(
                domain: .runtime,
                method: "getProperties",
                payload: GetPropertiesPayload(object: object, ownProperties: ownProperties),
                returning: [PropertyDescriptor].self
            )
        }

        public func preview(of object: RemoteObject.ID) async throws -> ObjectPreview {
            try await context.dispatch(
                domain: .runtime,
                method: "getPreview",
                payload: GetPreviewPayload(object: object),
                returning: ObjectPreview.self
            )
        }

        public func collectionEntries(of object: RemoteObject.ID) async throws -> [CollectionEntry] {
            try await context.dispatch(
                domain: .runtime,
                method: "getCollectionEntries",
                payload: GetCollectionEntriesPayload(object: object),
                returning: [CollectionEntry].self
            )
        }

        public func releaseObject(_ id: RemoteObject.ID) async throws {
            try await context.dispatchVoid(
                domain: .runtime,
                method: "releaseObject",
                payload: ReleaseObjectPayload(id: id)
            )
        }

        public func releaseObjectGroup(_ group: ObjectGroup) async throws {
            try await context.dispatchVoid(
                domain: .runtime,
                method: "releaseObjectGroup",
                payload: ReleaseObjectGroupPayload(group: group)
            )
        }

        public var events: EventStream {
            EventStream {
                context.runtimeEvents()
            }
        }
    }

    package struct EnablePayload: Sendable {
        package init() {}
    }

    package struct DisablePayload: Sendable {
        package init() {}
    }

    package struct EvaluatePayload: Sendable {
        package let expression: String
        package let context: ExecutionContext.ID?

        package init(expression: String, context: ExecutionContext.ID?) {
            self.expression = expression
            self.context = context
        }
    }

    package struct GetPropertiesPayload: Sendable {
        package let object: RemoteObject.ID
        package let ownProperties: Bool

        package init(object: RemoteObject.ID, ownProperties: Bool) {
            self.object = object
            self.ownProperties = ownProperties
        }
    }

    package struct GetPreviewPayload: Sendable {
        package let object: RemoteObject.ID

        package init(object: RemoteObject.ID) {
            self.object = object
        }
    }

    package struct GetCollectionEntriesPayload: Sendable {
        package let object: RemoteObject.ID

        package init(object: RemoteObject.ID) {
            self.object = object
        }
    }

    package struct ReleaseObjectPayload: Sendable {
        package let id: RemoteObject.ID

        package init(id: RemoteObject.ID) {
            self.id = id
        }
    }

    package struct ReleaseObjectGroupPayload: Sendable {
        package let group: ObjectGroup

        package init(group: ObjectGroup) {
            self.group = group
        }
    }

    public struct RemoteObject: Sendable {
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public let id: ID?
        public let kind: Kind
        public let subtype: Subtype?
        public let className: String?
        public let description: String?
        public let value: JSONValue?
        public let size: Int?
        public let preview: ObjectPreview?

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

    public enum Kind: Hashable, Sendable {
        case object
        case function
        case string
        case number
        case boolean
        case symbol
        case bigint
        case undefined
        case null
        case array
        case error
        case other(String)
    }

    public struct Subtype: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public indirect enum JSONValue: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])
    }

    public struct EvaluationResult: Sendable {
        public let object: RemoteObject
        public let wasThrown: Bool
        public let savedResultIndex: Int?

        public init(object: RemoteObject, wasThrown: Bool = false, savedResultIndex: Int? = nil) {
            self.object = object
            self.wasThrown = wasThrown
            self.savedResultIndex = savedResultIndex
        }
    }

    public struct ExecutionContext: Identifiable, Sendable {
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public let id: ID
        public let name: String
        public let frameID: FrameID?
        public let kind: ContextKind

        public init(id: ID, name: String, frameID: FrameID? = nil, kind: ContextKind) {
            self.id = id
            self.name = name
            self.frameID = frameID
            self.kind = kind
        }
    }

    public enum ContextKind: Hashable, Sendable {
        case normal
        case user
        case internalContext
        case other(String)
    }

    public enum ObjectGroup: Hashable, Sendable {
        case console
        case other(String)
    }

    public struct PropertyDescriptor: Sendable {
        public let name: String
        public let value: RemoteObject?
        public let writable: Bool?
        public let get: RemoteObject?
        public let set: RemoteObject?
        public let wasThrown: Bool?
        public let configurable: Bool?
        public let enumerable: Bool?
        public let isOwn: Bool?
        public let symbol: RemoteObject?
        public let isPrivate: Bool?
        public let nativeGetter: Bool?

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

    public struct ObjectPreview: Sendable {
        public let kind: Kind?
        public let subtype: Subtype?
        public let description: String?
        public let lossless: Bool
        public let overflow: Bool
        public let properties: [PropertyPreview]
        public let entries: [EntryPreview]
        public let size: Int?

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

    public struct PropertyPreview: Sendable {
        public let name: String
        public let value: String?

        public init(name: String, value: String? = nil) {
            self.name = name
            self.value = value
        }
    }

    public struct EntryPreview: Sendable {
        public let key: String?
        public let value: String?

        public init(key: String? = nil, value: String? = nil) {
            self.key = key
            self.value = value
        }
    }

    public struct CollectionEntry: Sendable {
        public let key: RemoteObject?
        public let value: RemoteObject

        public init(key: RemoteObject? = nil, value: RemoteObject) {
            self.key = key
            self.value = value
        }
    }

    public enum Event: Sendable {
        case executionContextCreated(ExecutionContext)
        case executionContextDestroyed(ExecutionContext.ID)
        case executionContextsCleared(target: WebInspectorTarget.ID)
        case unknown(RawEvent)
    }

    public struct EventStream: AsyncSequence, Sendable {
        public typealias Element = Event
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            makeStream().makeAsyncIterator()
        }
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
