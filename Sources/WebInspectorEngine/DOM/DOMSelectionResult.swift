import Foundation

public struct DOMSelectionResult: Decodable, Sendable {
    public struct SelectedAttribute: Decodable, Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let cancelled: Bool
    public let requiredDepth: Int
    public let selectedPath: [Int]?
    public let selectedLocalId: UInt64?
    public let ancestorLocalIds: [UInt64]?
    public let selectedBackendNodeId: UInt64?
    public let selectedBackendNodeIdIsStable: Bool?
    public let ancestorBackendNodeIds: [UInt64]?
    public let selectedAttributes: [SelectedAttribute]?
    public let selectedPreview: String?
    public let selectedSelectorPath: String?

    public init(
        cancelled: Bool,
        requiredDepth: Int,
        selectedPath: [Int]? = nil,
        selectedLocalId: UInt64? = nil,
        ancestorLocalIds: [UInt64]? = nil,
        selectedBackendNodeId: UInt64? = nil,
        selectedBackendNodeIdIsStable: Bool? = nil,
        ancestorBackendNodeIds: [UInt64]? = nil,
        selectedAttributes: [SelectedAttribute]? = nil,
        selectedPreview: String? = nil,
        selectedSelectorPath: String? = nil
    ) {
        self.cancelled = cancelled
        self.requiredDepth = requiredDepth
        self.selectedPath = selectedPath
        self.selectedLocalId = selectedLocalId
        self.ancestorLocalIds = ancestorLocalIds
        self.selectedBackendNodeId = selectedBackendNodeId
        self.selectedBackendNodeIdIsStable = selectedBackendNodeIdIsStable
        self.ancestorBackendNodeIds = ancestorBackendNodeIds
        self.selectedAttributes = selectedAttributes
        self.selectedPreview = selectedPreview
        self.selectedSelectorPath = selectedSelectorPath
    }
}
