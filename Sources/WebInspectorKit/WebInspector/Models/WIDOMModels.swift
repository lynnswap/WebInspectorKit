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

struct WISelectionResult: Decodable {
    let cancelled: Bool
    let requiredDepth: Int
}
