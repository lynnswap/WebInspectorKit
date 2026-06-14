import Foundation
import WebInspectorTransport

package enum RuntimeEvaluation {}
package enum RuntimeCommand {}

extension RuntimeRemoteObject {
    package enum Preview {}
    package enum PropertyPreview {}
    package enum EntryPreview {}
    package enum PropertyDescriptor {}
    package enum InternalPropertyDescriptor {}
    package enum CollectionEntry {}
}

extension RuntimeRemoteObject {
    package enum JSONValue: Equatable, Sendable, Codable {        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([RuntimeRemoteObject.JSONValue])
        case object([String: RuntimeRemoteObject.JSONValue])

        package init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int.self) {
                self = .number(Double(value))
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([RuntimeRemoteObject.JSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: RuntimeRemoteObject.JSONValue].self) {
                self = .object(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
            }
        }

        package func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case let .bool(value):
                try container.encode(value)
            case let .number(value):
                try container.encode(value)
            case let .string(value):
                try container.encode(value)
            case let .array(value):
                try container.encode(value)
            case let .object(value):
                try container.encode(value)
            }
        }

        package var foundationObject: Any {
            switch self {
            case .null:
                NSNull()
            case let .bool(value):
                value
            case let .number(value):
                value
            case let .string(value):
                value
            case let .array(value):
                value.map(\.foundationObject)
            case let .object(value):
                value.mapValues(\.foundationObject)
            }
        }
    }
}

extension RuntimeRemoteObject {
    package struct ProtocolID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package var description: String {
            rawValue
        }
    }
}

extension RuntimeRemoteObject {
    package struct ID: Hashable, Sendable {        package var runtimeAgentTargetID: ProtocolTarget.ID
        package var objectID: RuntimeRemoteObject.ProtocolID

        package init(runtimeAgentTargetID: ProtocolTarget.ID, objectID: RuntimeRemoteObject.ProtocolID) {
            self.runtimeAgentTargetID = runtimeAgentTargetID
            self.objectID = objectID
        }
    }
}

extension RuntimeRemoteObject {
    package struct Group: RawRepresentable, Hashable, Codable, Sendable {        package static let console = Self("console")

        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension RuntimeRemoteObject {
    package struct Kind: RawRepresentable, Hashable, Codable, Sendable {        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package static let object = Self("object")
        package static let function = Self("function")
        package static let undefined = Self("undefined")
        package static let string = Self("string")
        package static let number = Self("number")
        package static let boolean = Self("boolean")
        package static let symbol = Self("symbol")
        package static let bigint = Self("bigint")
    }
}

extension RuntimeRemoteObject {
    package struct Subtype: RawRepresentable, Hashable, Codable, Sendable {        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package static let array = Self("array")
        package static let null = Self("null")
        package static let node = Self("node")
        package static let regexp = Self("regexp")
        package static let date = Self("date")
        package static let error = Self("error")
        package static let map = Self("map")
        package static let set = Self("set")
        package static let weakMap = Self("weakmap")
        package static let weakSet = Self("weakset")
        package static let iterator = Self("iterator")
        package static let `class` = Self("class")
        package static let proxy = Self("proxy")
        package static let weakRef = Self("weakref")
    }
}

extension RuntimeExecutionContext {
    package struct Payload: Equatable, Sendable, Decodable {        package var id: RuntimeContext.ID
        package var type: RuntimeContext.Kind?
        package var name: String?
        package var frameID: DOMFrame.ID?

        package init(
            id: RuntimeContext.ID,
            type: RuntimeContext.Kind? = nil,
            name: String? = nil,
            frameID: DOMFrame.ID? = nil
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.frameID = frameID
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case type
            case name
            case frameID = "frameId"
        }
    }
}

extension RuntimeRemoteObject {
    package final class PayloadBox: Codable, Equatable, Sendable {        package let value: RuntimeRemoteObject.Payload

        package init(_ value: RuntimeRemoteObject.Payload) {
            self.value = value
        }

        package init(from decoder: any Decoder) throws {
            value = try RuntimeRemoteObject.Payload(from: decoder)
        }

        package func encode(to encoder: any Encoder) throws {
            try value.encode(to: encoder)
        }

        package static func == (lhs: RuntimeRemoteObject.PayloadBox, rhs: RuntimeRemoteObject.PayloadBox) -> Bool {
            lhs.value == rhs.value
        }
    }
}

extension RuntimeRemoteObject.Preview {
    package final class PayloadBox: Codable, Equatable, Sendable {        package let value: RuntimeRemoteObject.Preview.Payload

        package init(_ value: RuntimeRemoteObject.Preview.Payload) {
            self.value = value
        }

        package init(from decoder: any Decoder) throws {
            value = try RuntimeRemoteObject.Preview.Payload(from: decoder)
        }

        package func encode(to encoder: any Encoder) throws {
            try value.encode(to: encoder)
        }

        package static func == (lhs: RuntimeRemoteObject.Preview.PayloadBox, rhs: RuntimeRemoteObject.Preview.PayloadBox) -> Bool {
            lhs.value == rhs.value
        }
    }
}

extension RuntimeRemoteObject {
    package struct Payload: Equatable, Sendable, Codable {        package var type: RuntimeRemoteObject.Kind
        package var subtype: RuntimeRemoteObject.Subtype?
        package var className: String?
        package var value: RuntimeRemoteObject.JSONValue?
        package var description: String?
        package var objectID: RuntimeRemoteObject.ProtocolID?
        package var size: Int?
        package var classPrototype: RuntimeRemoteObject.PayloadBox?
        package var preview: RuntimeRemoteObject.Preview.Payload?

        package init(
            type: RuntimeRemoteObject.Kind,
            subtype: RuntimeRemoteObject.Subtype? = nil,
            className: String? = nil,
            value: RuntimeRemoteObject.JSONValue? = nil,
            description: String? = nil,
            objectID: RuntimeRemoteObject.ProtocolID? = nil,
            size: Int? = nil,
            classPrototype: RuntimeRemoteObject.PayloadBox? = nil,
            preview: RuntimeRemoteObject.Preview.Payload? = nil
        ) {
            self.type = type
            self.subtype = subtype
            self.className = className
            self.value = value
            self.description = description
            self.objectID = objectID
            self.size = size
            self.classPrototype = classPrototype
            self.preview = preview
        }

        package func identifierKey(runtimeAgentTargetID: ProtocolTarget.ID) -> RuntimeRemoteObject.ID? {
            objectID.map { RuntimeRemoteObject.ID(runtimeAgentTargetID: runtimeAgentTargetID, objectID: $0) }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case subtype
            case className
            case value
            case description
            case objectID = "objectId"
            case size
            case classPrototype
            case preview
        }
    }
}

extension RuntimeRemoteObject.Preview {
    package struct Payload: Equatable, Sendable, Codable {        package var type: RuntimeRemoteObject.Kind
        package var subtype: RuntimeRemoteObject.Subtype?
        package var description: String?
        package var lossless: Bool
        package var overflow: Bool?
        package var properties: [RuntimeRemoteObject.PropertyPreview.Payload]
        package var entries: [RuntimeRemoteObject.EntryPreview.Payload]
        package var size: Int?

        package init(
            type: RuntimeRemoteObject.Kind,
            subtype: RuntimeRemoteObject.Subtype? = nil,
            description: String? = nil,
            lossless: Bool,
            overflow: Bool? = nil,
            properties: [RuntimeRemoteObject.PropertyPreview.Payload] = [],
            entries: [RuntimeRemoteObject.EntryPreview.Payload] = [],
            size: Int? = nil
        ) {
            self.type = type
            self.subtype = subtype
            self.description = description
            self.lossless = lossless
            self.overflow = overflow
            self.properties = properties
            self.entries = entries
            self.size = size
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case subtype
            case description
            case lossless
            case overflow
            case properties
            case entries
            case size
        }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(RuntimeRemoteObject.Kind.self, forKey: .type)
            subtype = try container.decodeIfPresent(RuntimeRemoteObject.Subtype.self, forKey: .subtype)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            lossless = try container.decodeIfPresent(Bool.self, forKey: .lossless) ?? false
            overflow = try container.decodeIfPresent(Bool.self, forKey: .overflow)
            properties = try container.decodeIfPresent([RuntimeRemoteObject.PropertyPreview.Payload].self, forKey: .properties) ?? []
            entries = try container.decodeIfPresent([RuntimeRemoteObject.EntryPreview.Payload].self, forKey: .entries) ?? []
            size = try container.decodeIfPresent(Int.self, forKey: .size)
        }
    }
}

extension RuntimeRemoteObject.PropertyPreview {
    package struct Payload: Equatable, Sendable, Codable {        package var name: String
        package var type: RuntimeRemoteObject.Kind
        package var subtype: RuntimeRemoteObject.Subtype?
        package var value: String?
        package var valuePreview: RuntimeRemoteObject.Preview.PayloadBox?
        package var isPrivate: Bool?
        package var isInternal: Bool?

        package init(
            name: String,
            type: RuntimeRemoteObject.Kind,
            subtype: RuntimeRemoteObject.Subtype? = nil,
            value: String? = nil,
            valuePreview: RuntimeRemoteObject.Preview.PayloadBox? = nil,
            isPrivate: Bool? = nil,
            isInternal: Bool? = nil
        ) {
            self.name = name
            self.type = type
            self.subtype = subtype
            self.value = value
            self.valuePreview = valuePreview
            self.isPrivate = isPrivate
            self.isInternal = isInternal
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case type
            case subtype
            case value
            case valuePreview
            case isPrivate
            case isInternal = "internal"
        }
    }
}

extension RuntimeRemoteObject.EntryPreview {
    package struct Payload: Equatable, Sendable, Codable {        package var key: RuntimeRemoteObject.Preview.PayloadBox?
        package var value: RuntimeRemoteObject.Preview.PayloadBox

        package init(key: RuntimeRemoteObject.Preview.PayloadBox? = nil, value: RuntimeRemoteObject.Preview.PayloadBox) {
            self.key = key
            self.value = value
        }
    }
}

extension RuntimeRemoteObject.PropertyDescriptor {
    package struct Payload: Equatable, Sendable, Codable {        package var name: String
        package var value: RuntimeRemoteObject.Payload?
        package var writable: Bool?
        package var get: RuntimeRemoteObject.Payload?
        package var set: RuntimeRemoteObject.Payload?
        package var wasThrown: Bool?
        package var configurable: Bool?
        package var enumerable: Bool?
        package var isOwn: Bool?
        package var symbol: RuntimeRemoteObject.Payload?
        package var isPrivate: Bool?
        package var nativeGetter: Bool?

        package init(
            name: String,
            value: RuntimeRemoteObject.Payload? = nil,
            writable: Bool? = nil,
            get: RuntimeRemoteObject.Payload? = nil,
            set: RuntimeRemoteObject.Payload? = nil,
            wasThrown: Bool? = nil,
            configurable: Bool? = nil,
            enumerable: Bool? = nil,
            isOwn: Bool? = nil,
            symbol: RuntimeRemoteObject.Payload? = nil,
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
}

extension RuntimeRemoteObject.InternalPropertyDescriptor {
    package struct Payload: Equatable, Sendable, Codable {        package var name: String
        package var value: RuntimeRemoteObject.Payload?

        package init(name: String, value: RuntimeRemoteObject.Payload? = nil) {
            self.name = name
            self.value = value
        }
    }
}

extension RuntimeRemoteObject.CollectionEntry {
    package struct Payload: Equatable, Sendable, Codable {        package var key: RuntimeRemoteObject.Payload?
        package var value: RuntimeRemoteObject.Payload

        package init(key: RuntimeRemoteObject.Payload? = nil, value: RuntimeRemoteObject.Payload) {
            self.key = key
            self.value = value
        }
    }
}

extension RuntimeEvaluation {
    package struct ResultPayload: Equatable, Sendable, Codable {        package var result: RuntimeRemoteObject.Payload
        package var wasThrown: Bool
        package var savedResultIndex: Int?

        package init(result: RuntimeRemoteObject.Payload, wasThrown: Bool = false, savedResultIndex: Int? = nil) {
            self.result = result
            self.wasThrown = wasThrown
            self.savedResultIndex = savedResultIndex
        }

        private enum CodingKeys: String, CodingKey {
            case result
            case wasThrown
            case savedResultIndex
        }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            result = try container.decode(RuntimeRemoteObject.Payload.self, forKey: .result)
            wasThrown = try container.decodeIfPresent(Bool.self, forKey: .wasThrown) ?? false
            savedResultIndex = try container.decodeIfPresent(Int.self, forKey: .savedResultIndex)
        }
    }
}

extension RuntimeRemoteObject {
    package struct PropertiesResultPayload: Equatable, Sendable, Codable {        package var properties: [RuntimeRemoteObject.PropertyDescriptor.Payload]
        package var internalProperties: [RuntimeRemoteObject.InternalPropertyDescriptor.Payload]

        package init(
            properties: [RuntimeRemoteObject.PropertyDescriptor.Payload] = [],
            internalProperties: [RuntimeRemoteObject.InternalPropertyDescriptor.Payload] = []
        ) {
            self.properties = properties
            self.internalProperties = internalProperties
        }

        private enum CodingKeys: String, CodingKey {
            case properties
            case internalProperties
        }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            properties = try container.decodeIfPresent([RuntimeRemoteObject.PropertyDescriptor.Payload].self, forKey: .properties) ?? []
            internalProperties = try container.decodeIfPresent(
                [RuntimeRemoteObject.InternalPropertyDescriptor.Payload].self,
                forKey: .internalProperties
            ) ?? []
        }
    }
}

extension RuntimeRemoteObject {
    package struct CollectionEntriesResultPayload: Equatable, Sendable, Codable {        package var entries: [RuntimeRemoteObject.CollectionEntry.Payload]

        package init(entries: [RuntimeRemoteObject.CollectionEntry.Payload] = []) {
            self.entries = entries
        }
    }
}

extension RuntimeRemoteObject.Preview {
    package struct ResultPayload: Equatable, Sendable, Codable {        package var preview: RuntimeRemoteObject.Preview.Payload

        package init(preview: RuntimeRemoteObject.Preview.Payload) {
            self.preview = preview
        }
    }
}

extension RuntimeEvaluation {
    package struct SaveResultPayload: Equatable, Sendable, Codable {        package var savedResultIndex: Int?

        package init(savedResultIndex: Int? = nil) {
            self.savedResultIndex = savedResultIndex
        }
    }
}

extension RuntimeEvaluation {
    package struct CallArgumentPayload: Equatable, Sendable {        package var value: RuntimeRemoteObject.JSONValue?
        package var objectID: RuntimeRemoteObject.ProtocolID?

        package init(value: RuntimeRemoteObject.JSONValue? = nil, objectID: RuntimeRemoteObject.ProtocolID? = nil) {
            self.value = value
            self.objectID = objectID
        }

        package var parametersObject: [String: Any] {
            var object: [String: Any] = [:]
            if let value {
                object["value"] = value.foundationObject
            }
            if let objectID {
                object["objectId"] = objectID.rawValue
            }
            return object
        }
    }
}

extension RuntimeEvaluation {
    package struct Request: Equatable, Sendable {        package var runtimeAgentTargetID: ProtocolTarget.ID
        package var expression: String
        package var objectGroup: RuntimeRemoteObject.Group?
        package var includeCommandLineAPI: Bool?
        package var doNotPauseOnExceptionsAndMuteConsole: Bool?
        package var contextID: RuntimeContext.ID?
        package var returnByValue: Bool?
        package var generatePreview: Bool?
        package var saveResult: Bool?
        package var emulateUserGesture: Bool?

        package init(
            runtimeAgentTargetID: ProtocolTarget.ID,
            expression: String,
            objectGroup: RuntimeRemoteObject.Group? = nil,
            includeCommandLineAPI: Bool? = nil,
            doNotPauseOnExceptionsAndMuteConsole: Bool? = nil,
            contextID: RuntimeContext.ID? = nil,
            returnByValue: Bool? = nil,
            generatePreview: Bool? = nil,
            saveResult: Bool? = nil,
            emulateUserGesture: Bool? = nil
        ) {
            self.runtimeAgentTargetID = runtimeAgentTargetID
            self.expression = expression
            self.objectGroup = objectGroup
            self.includeCommandLineAPI = includeCommandLineAPI
            self.doNotPauseOnExceptionsAndMuteConsole = doNotPauseOnExceptionsAndMuteConsole
            self.contextID = contextID
            self.returnByValue = returnByValue
            self.generatePreview = generatePreview
            self.saveResult = saveResult
            self.emulateUserGesture = emulateUserGesture
        }
    }
}

extension RuntimeCommand {
    package enum Intent: Equatable, Sendable {        case enable(targetID: ProtocolTarget.ID)
        case evaluate(RuntimeEvaluation.Request)
        case getPreview(object: RuntimeRemoteObject.ID)
        case getProperties(
            object: RuntimeRemoteObject.ID,
            ownProperties: Bool?,
            fetchStart: Int?,
            fetchCount: Int?,
            generatePreview: Bool?
        )
        case getDisplayableProperties(
            object: RuntimeRemoteObject.ID,
            fetchStart: Int?,
            fetchCount: Int?,
            generatePreview: Bool?
        )
        case getCollectionEntries(
            object: RuntimeRemoteObject.ID,
            objectGroup: RuntimeRemoteObject.Group?,
            fetchStart: Int?,
            fetchCount: Int?
        )
        case saveResult(targetID: ProtocolTarget.ID, argument: RuntimeEvaluation.CallArgumentPayload, contextID: RuntimeContext.ID?)
        case setSavedResultAlias(targetID: ProtocolTarget.ID, alias: String?)
        case releaseObject(RuntimeRemoteObject.ID)
        case releaseObjectGroup(runtimeAgentTargetID: ProtocolTarget.ID, objectGroup: RuntimeRemoteObject.Group)

        package var routingTargetID: ProtocolTarget.ID {
            switch self {
            case let .enable(targetID):
                targetID
            case let .evaluate(request):
                request.runtimeAgentTargetID
            case let .getPreview(object):
                object.runtimeAgentTargetID
            case let .getProperties(object, _, _, _, _):
                object.runtimeAgentTargetID
            case let .getDisplayableProperties(object, _, _, _):
                object.runtimeAgentTargetID
            case let .getCollectionEntries(object, _, _, _):
                object.runtimeAgentTargetID
            case let .saveResult(targetID, _, _):
                targetID
            case let .setSavedResultAlias(targetID, _):
                targetID
            case let .releaseObject(object):
                object.runtimeAgentTargetID
            case let .releaseObjectGroup(runtimeAgentTargetID, _):
                runtimeAgentTargetID
            }
        }
    }
}
