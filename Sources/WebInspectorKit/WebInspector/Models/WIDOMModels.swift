import Foundation

struct WISnapshotPackage {
    let rawJSON: String
}

struct WISubtreePayload: Equatable {
    let rawJSON: String
}

struct WIDOMUpdatePayload: Equatable {
    let rawJSON: String
}

public struct WIDOMAttribute: Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct WIDOMSelection: Equatable {
    public let nodeId: Int?
    public let preview: String
    public let attributes: [WIDOMAttribute]
    public let path: [String]

    public init(
        nodeId: Int?,
        preview: String,
        attributes: [WIDOMAttribute],
        path: [String]
    ) {
        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
    }
}

struct WISelectionResult: Decodable {
    let cancelled: Bool
    let requiredDepth: Int
}
