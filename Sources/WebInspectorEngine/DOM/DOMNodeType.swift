import Foundation

public enum DOMNodeType: Int, Hashable, Sendable, Codable {
    case unknown = 0
    case element = 1
    case attribute = 2
    case text = 3
    case cdataSection = 4
    case entityReference = 5
    case entity = 6
    case processingInstruction = 7
    case comment = 8
    case document = 9
    case documentType = 10
    case documentFragment = 11
    case notation = 12

    public init(protocolValue: Int) {
        self = Self(rawValue: protocolValue) ?? .unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(protocolValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
