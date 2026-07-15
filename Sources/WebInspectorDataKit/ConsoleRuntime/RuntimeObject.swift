import Foundation
import WebInspectorProxyKit

/// An immutable, actor-independent snapshot of one Runtime value.
public struct RuntimeObject: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        package enum Storage: Hashable, Sendable {
            case consoleParameter(
                messageID: ConsoleMessage.ID,
                parameterIndex: Int
            )
            case scope(scopeID: UUID, ordinal: UInt64)
        }

        package let storage: Storage

        package init(
            consoleMessageID: ConsoleMessage.ID,
            parameterIndex: Int
        ) {
            storage = .consoleParameter(
                messageID: consoleMessageID,
                parameterIndex: parameterIndex
            )
        }

        package init(scopeID: UUID, ordinal: UInt64) {
            storage = .scope(scopeID: scopeID, ordinal: ordinal)
        }
    }

    public struct Property: Sendable {
        public let name: String
        public let value: String?
        public let object: RuntimeObject?

        public init(
            name: String,
            value: String? = nil,
            object: RuntimeObject? = nil
        ) {
            self.name = name
            self.value = value
            self.object = object
        }
    }

    public struct Entry: Sendable {
        public let key: RuntimeObject?
        public let value: RuntimeObject?

        public init(key: RuntimeObject? = nil, value: RuntimeObject? = nil) {
            self.key = key
            self.value = value
        }
    }

    public let id: ID
    public let kind: Runtime.Kind
    public let subtype: Runtime.Subtype?
    public let className: String?
    public let value: Runtime.JSONValue?
    public let description: String?
    public let size: Int?
    public let preview: Runtime.ObjectPreview?
    public let canRequestProperties: Bool

    package init(
        id: ID,
        payload: CanonicalRuntimeRemoteObjectPayload
    ) {
        self.id = id
        kind = payload.kind
        subtype = payload.subtype
        className = payload.className
        value = payload.value
        description = payload.description
        size = payload.size
        preview = payload.preview?.objectPreview
        canRequestProperties = payload.rawObjectID != nil
    }

    package init(id: ID, remoteObject: Runtime.RemoteObject) {
        self.id = id
        kind = remoteObject.kind
        subtype = remoteObject.subtype
        className = remoteObject.className
        value = remoteObject.value
        description = remoteObject.description
        size = remoteObject.size
        preview = remoteObject.preview
        canRequestProperties = remoteObject.id != nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

package extension CanonicalRuntimeObjectPreview {
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

public typealias RuntimeProperty = RuntimeObject.Property
public typealias RuntimeObjectPreview = Runtime.ObjectPreview

public struct RuntimeEvaluation: Sendable {
    public let object: RuntimeObject
    public let isException: Bool

    public init(object: RuntimeObject, isException: Bool) {
        self.object = object
        self.isException = isException
    }
}
