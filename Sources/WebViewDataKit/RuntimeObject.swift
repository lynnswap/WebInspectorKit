import Foundation
import Observation
import WebViewProxyKit

@MainActor
@Observable
public final class RuntimeObject: Identifiable {
    public struct ID: Hashable, Sendable {
        package enum Storage: Hashable, Sendable {
            case remote(Runtime.RemoteObject.ID)
            case synthetic(Int)
        }

        package let storage: Storage

        package init(remote id: Runtime.RemoteObject.ID) {
            storage = .remote(id)
        }

        package init(synthetic ordinal: Int) {
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

    @ObservationIgnored package weak var modelContext: WebViewModelContext?
    @ObservationIgnored package var proxyID: Runtime.RemoteObject.ID?

    public var canRequestProperties: Bool {
        proxyID != nil
    }

    package init(
        id: ID,
        remoteObject: Runtime.RemoteObject,
        modelContext: WebViewModelContext
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

    public func properties() async throws -> [Property] {
        guard canRequestProperties else {
            return []
        }
        guard let modelContext else {
            throw WebViewProxyError.disconnected("RuntimeObject is not registered in a WebViewModelContext.")
        }
        return try await modelContext.properties(for: self)
    }

    public func collectionEntries() async throws -> [Entry] {
        guard canRequestProperties else {
            return []
        }
        guard let modelContext else {
            throw WebViewProxyError.disconnected("RuntimeObject is not registered in a WebViewModelContext.")
        }
        return try await modelContext.collectionEntries(for: self)
    }

    package func update(from remoteObject: Runtime.RemoteObject) {
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
