import Foundation
import Observation
import WebInspectorProxyKit

@Observable
public final class RuntimeObject: WebInspectorPersistentModel {
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

    public struct Property {
        public let name: String
        public let value: String?
        public let object: RuntimeObject?

        public init(name: String, value: String? = nil, object: RuntimeObject? = nil) {
            self.name = name
            self.value = value
            self.object = object
        }
    }

    public struct Entry {
        public let key: RuntimeObject?
        public let value: RuntimeObject?

        public init(key: RuntimeObject? = nil, value: RuntimeObject? = nil) {
            self.key = key
            self.value = value
        }
    }

    public let id: ID
    public private(set) var kind: Runtime.Kind
    public private(set) var subtype: Runtime.Subtype?
    public private(set) var className: String?
    public private(set) var value: Runtime.JSONValue?
    public private(set) var description: String?
    public private(set) var size: Int?
    public private(set) var preview: Runtime.ObjectPreview?

    @ObservationIgnored weak var modelContext: WebInspectorContext?
    @ObservationIgnored var proxyID: Runtime.RemoteObject.ID?

    public var canRequestProperties: Bool {
        proxyID != nil
    }

    init(
        id: ID,
        remoteObject: Runtime.RemoteObject,
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
        self.modelContext = modelContext
    }

    public func properties(isolation: isolated (any Actor) = #isolation) async throws -> [Property] {
        guard canRequestProperties else {
            return []
        }
        guard let modelContext else {
            throw WebInspectorProxyError.disconnected("RuntimeObject is not registered in a WebInspectorContext.")
        }
        return try await modelContext.properties(for: self, isolation: isolation)
    }

    public func collectionEntries(isolation: isolated (any Actor) = #isolation) async throws -> [Entry] {
        guard canRequestProperties else {
            return []
        }
        guard let modelContext else {
            throw WebInspectorProxyError.disconnected("RuntimeObject is not registered in a WebInspectorContext.")
        }
        return try await modelContext.collectionEntries(for: self, isolation: isolation)
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

public struct RuntimeEvaluation {
    public let object: RuntimeObject
    public let isException: Bool

    public init(object: RuntimeObject, isException: Bool) {
        self.object = object
        self.isException = isException
    }
}
