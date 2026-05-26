import Foundation

package enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

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
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
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

package struct RuntimeRemoteObjectIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    package let rawValue: String

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

package struct RuntimeRemoteObjectIdentifierKey: Hashable, Sendable {
    package var runtimeAgentTargetID: ProtocolTargetIdentifier
    package var objectID: RuntimeRemoteObjectIdentifier

    package init(runtimeAgentTargetID: ProtocolTargetIdentifier, objectID: RuntimeRemoteObjectIdentifier) {
        self.runtimeAgentTargetID = runtimeAgentTargetID
        self.objectID = objectID
    }
}

package struct RuntimeExecutionContextKey: Hashable, Sendable {
    package var runtimeAgentTargetID: ProtocolTargetIdentifier
    package var contextID: ExecutionContextID

    package init(runtimeAgentTargetID: ProtocolTargetIdentifier, contextID: ExecutionContextID) {
        self.runtimeAgentTargetID = runtimeAgentTargetID
        self.contextID = contextID
    }
}

package struct RuntimeObjectGroup: RawRepresentable, Hashable, Codable, Sendable {
    package static let console = Self("console")

    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

package struct RuntimeRemoteObjectType: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

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

package struct RuntimeRemoteObjectSubtype: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

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

package struct RuntimeExecutionContextType: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let normal = Self("normal")
    package static let user = Self("user")
    package static let `internal` = Self("internal")
}

package struct RuntimeExecutionContextPayload: Equatable, Sendable, Decodable {
    package var id: ExecutionContextID
    package var type: RuntimeExecutionContextType?
    package var name: String?
    package var frameID: DOMFrameIdentifier?

    package init(
        id: ExecutionContextID,
        type: RuntimeExecutionContextType? = nil,
        name: String? = nil,
        frameID: DOMFrameIdentifier? = nil
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

package final class RuntimeRemoteObjectPayloadBox: Codable, Equatable, @unchecked Sendable {
    package let value: RuntimeRemoteObjectPayload

    package init(_ value: RuntimeRemoteObjectPayload) {
        self.value = value
    }

    package init(from decoder: any Decoder) throws {
        value = try RuntimeRemoteObjectPayload(from: decoder)
    }

    package func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    package static func == (lhs: RuntimeRemoteObjectPayloadBox, rhs: RuntimeRemoteObjectPayloadBox) -> Bool {
        lhs.value == rhs.value
    }
}

package final class RuntimeObjectPreviewPayloadBox: Codable, Equatable, @unchecked Sendable {
    package let value: RuntimeObjectPreviewPayload

    package init(_ value: RuntimeObjectPreviewPayload) {
        self.value = value
    }

    package init(from decoder: any Decoder) throws {
        value = try RuntimeObjectPreviewPayload(from: decoder)
    }

    package func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    package static func == (lhs: RuntimeObjectPreviewPayloadBox, rhs: RuntimeObjectPreviewPayloadBox) -> Bool {
        lhs.value == rhs.value
    }
}

package struct RuntimeRemoteObjectPayload: Equatable, Sendable, Codable {
    package var type: RuntimeRemoteObjectType
    package var subtype: RuntimeRemoteObjectSubtype?
    package var className: String?
    package var value: JSONValue?
    package var description: String?
    package var objectID: RuntimeRemoteObjectIdentifier?
    package var size: Int?
    package var classPrototype: RuntimeRemoteObjectPayloadBox?
    package var preview: RuntimeObjectPreviewPayload?

    package init(
        type: RuntimeRemoteObjectType,
        subtype: RuntimeRemoteObjectSubtype? = nil,
        className: String? = nil,
        value: JSONValue? = nil,
        description: String? = nil,
        objectID: RuntimeRemoteObjectIdentifier? = nil,
        size: Int? = nil,
        classPrototype: RuntimeRemoteObjectPayloadBox? = nil,
        preview: RuntimeObjectPreviewPayload? = nil
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

    package func identifierKey(runtimeAgentTargetID: ProtocolTargetIdentifier) -> RuntimeRemoteObjectIdentifierKey? {
        objectID.map { RuntimeRemoteObjectIdentifierKey(runtimeAgentTargetID: runtimeAgentTargetID, objectID: $0) }
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

package struct RuntimeObjectPreviewPayload: Equatable, Sendable, Codable {
    package var type: RuntimeRemoteObjectType
    package var subtype: RuntimeRemoteObjectSubtype?
    package var description: String?
    package var lossless: Bool
    package var overflow: Bool?
    package var properties: [RuntimePropertyPreviewPayload]
    package var entries: [RuntimeEntryPreviewPayload]
    package var size: Int?

    package init(
        type: RuntimeRemoteObjectType,
        subtype: RuntimeRemoteObjectSubtype? = nil,
        description: String? = nil,
        lossless: Bool,
        overflow: Bool? = nil,
        properties: [RuntimePropertyPreviewPayload] = [],
        entries: [RuntimeEntryPreviewPayload] = [],
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
        type = try container.decode(RuntimeRemoteObjectType.self, forKey: .type)
        subtype = try container.decodeIfPresent(RuntimeRemoteObjectSubtype.self, forKey: .subtype)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        lossless = try container.decodeIfPresent(Bool.self, forKey: .lossless) ?? false
        overflow = try container.decodeIfPresent(Bool.self, forKey: .overflow)
        properties = try container.decodeIfPresent([RuntimePropertyPreviewPayload].self, forKey: .properties) ?? []
        entries = try container.decodeIfPresent([RuntimeEntryPreviewPayload].self, forKey: .entries) ?? []
        size = try container.decodeIfPresent(Int.self, forKey: .size)
    }
}

package struct RuntimePropertyPreviewPayload: Equatable, Sendable, Codable {
    package var name: String
    package var type: RuntimeRemoteObjectType
    package var subtype: RuntimeRemoteObjectSubtype?
    package var value: String?
    package var valuePreview: RuntimeObjectPreviewPayloadBox?
    package var isPrivate: Bool?
    package var isInternal: Bool?

    package init(
        name: String,
        type: RuntimeRemoteObjectType,
        subtype: RuntimeRemoteObjectSubtype? = nil,
        value: String? = nil,
        valuePreview: RuntimeObjectPreviewPayloadBox? = nil,
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

package struct RuntimeEntryPreviewPayload: Equatable, Sendable, Codable {
    package var key: RuntimeObjectPreviewPayloadBox?
    package var value: RuntimeObjectPreviewPayloadBox

    package init(key: RuntimeObjectPreviewPayloadBox? = nil, value: RuntimeObjectPreviewPayloadBox) {
        self.key = key
        self.value = value
    }
}

package struct RuntimePropertyDescriptorPayload: Equatable, Sendable, Codable {
    package var name: String
    package var value: RuntimeRemoteObjectPayload?
    package var writable: Bool?
    package var get: RuntimeRemoteObjectPayload?
    package var set: RuntimeRemoteObjectPayload?
    package var wasThrown: Bool?
    package var configurable: Bool?
    package var enumerable: Bool?
    package var isOwn: Bool?
    package var symbol: RuntimeRemoteObjectPayload?
    package var isPrivate: Bool?
    package var nativeGetter: Bool?

    package init(
        name: String,
        value: RuntimeRemoteObjectPayload? = nil,
        writable: Bool? = nil,
        get: RuntimeRemoteObjectPayload? = nil,
        set: RuntimeRemoteObjectPayload? = nil,
        wasThrown: Bool? = nil,
        configurable: Bool? = nil,
        enumerable: Bool? = nil,
        isOwn: Bool? = nil,
        symbol: RuntimeRemoteObjectPayload? = nil,
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

package struct RuntimeInternalPropertyDescriptorPayload: Equatable, Sendable, Codable {
    package var name: String
    package var value: RuntimeRemoteObjectPayload?

    package init(name: String, value: RuntimeRemoteObjectPayload? = nil) {
        self.name = name
        self.value = value
    }
}

package struct RuntimeCollectionEntryPayload: Equatable, Sendable, Codable {
    package var key: RuntimeRemoteObjectPayload?
    package var value: RuntimeRemoteObjectPayload

    package init(key: RuntimeRemoteObjectPayload? = nil, value: RuntimeRemoteObjectPayload) {
        self.key = key
        self.value = value
    }
}

package struct RuntimeEvaluationResultPayload: Equatable, Sendable, Codable {
    package var result: RuntimeRemoteObjectPayload
    package var wasThrown: Bool
    package var savedResultIndex: Int?

    package init(result: RuntimeRemoteObjectPayload, wasThrown: Bool = false, savedResultIndex: Int? = nil) {
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
        result = try container.decode(RuntimeRemoteObjectPayload.self, forKey: .result)
        wasThrown = try container.decodeIfPresent(Bool.self, forKey: .wasThrown) ?? false
        savedResultIndex = try container.decodeIfPresent(Int.self, forKey: .savedResultIndex)
    }
}

package struct RuntimePropertiesResultPayload: Equatable, Sendable, Codable {
    package var properties: [RuntimePropertyDescriptorPayload]
    package var internalProperties: [RuntimeInternalPropertyDescriptorPayload]

    package init(
        properties: [RuntimePropertyDescriptorPayload] = [],
        internalProperties: [RuntimeInternalPropertyDescriptorPayload] = []
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
        properties = try container.decodeIfPresent([RuntimePropertyDescriptorPayload].self, forKey: .properties) ?? []
        internalProperties = try container.decodeIfPresent(
            [RuntimeInternalPropertyDescriptorPayload].self,
            forKey: .internalProperties
        ) ?? []
    }
}

package struct RuntimeCollectionEntriesResultPayload: Equatable, Sendable, Codable {
    package var entries: [RuntimeCollectionEntryPayload]

    package init(entries: [RuntimeCollectionEntryPayload] = []) {
        self.entries = entries
    }
}

package struct RuntimePreviewResultPayload: Equatable, Sendable, Codable {
    package var preview: RuntimeObjectPreviewPayload

    package init(preview: RuntimeObjectPreviewPayload) {
        self.preview = preview
    }
}

package struct RuntimeSaveResultPayload: Equatable, Sendable, Codable {
    package var savedResultIndex: Int?

    package init(savedResultIndex: Int? = nil) {
        self.savedResultIndex = savedResultIndex
    }
}

package struct RuntimeCallArgumentPayload: Equatable, Sendable {
    package var value: JSONValue?
    package var objectID: RuntimeRemoteObjectIdentifier?

    package init(value: JSONValue? = nil, objectID: RuntimeRemoteObjectIdentifier? = nil) {
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

package struct RuntimeEvaluationRequest: Equatable, Sendable {
    package var runtimeAgentTargetID: ProtocolTargetIdentifier
    package var expression: String
    package var objectGroup: RuntimeObjectGroup?
    package var includeCommandLineAPI: Bool?
    package var doNotPauseOnExceptionsAndMuteConsole: Bool?
    package var contextID: ExecutionContextID?
    package var returnByValue: Bool?
    package var generatePreview: Bool?
    package var saveResult: Bool?
    package var emulateUserGesture: Bool?

    package init(
        runtimeAgentTargetID: ProtocolTargetIdentifier,
        expression: String,
        objectGroup: RuntimeObjectGroup? = nil,
        includeCommandLineAPI: Bool? = nil,
        doNotPauseOnExceptionsAndMuteConsole: Bool? = nil,
        contextID: ExecutionContextID? = nil,
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

package enum RuntimeCommandIntent: Equatable, Sendable {
    case enable(targetID: ProtocolTargetIdentifier)
    case evaluate(RuntimeEvaluationRequest)
    case getPreview(object: RuntimeRemoteObjectIdentifierKey)
    case getProperties(
        object: RuntimeRemoteObjectIdentifierKey,
        ownProperties: Bool?,
        fetchStart: Int?,
        fetchCount: Int?,
        generatePreview: Bool?
    )
    case getDisplayableProperties(
        object: RuntimeRemoteObjectIdentifierKey,
        fetchStart: Int?,
        fetchCount: Int?,
        generatePreview: Bool?
    )
    case getCollectionEntries(
        object: RuntimeRemoteObjectIdentifierKey,
        objectGroup: RuntimeObjectGroup?,
        fetchStart: Int?,
        fetchCount: Int?
    )
    case saveResult(targetID: ProtocolTargetIdentifier, argument: RuntimeCallArgumentPayload, contextID: ExecutionContextID?)
    case setSavedResultAlias(targetID: ProtocolTargetIdentifier, alias: String?)
    case releaseObject(RuntimeRemoteObjectIdentifierKey)
    case releaseObjectGroup(runtimeAgentTargetID: ProtocolTargetIdentifier, objectGroup: RuntimeObjectGroup)

    package var routingTargetID: ProtocolTargetIdentifier {
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
