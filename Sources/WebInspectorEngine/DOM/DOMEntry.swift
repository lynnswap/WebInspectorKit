import Foundation
import Observation

@available(*, deprecated, renamed: "DOMNodeModel", message: "Use DOMNodeModel.")
public typealias DOMEntry = DOMNodeModel

public struct DOMAttribute: Hashable, Identifiable, Sendable {
    public var id: String {
        name
    }

    package var nodeId: Int?
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.nodeId = nil
        self.name = name
        self.value = value
    }

    package init(nodeId: Int? = nil, name: String, value: String) {
        self.nodeId = nodeId
        self.name = name
        self.value = value
    }
}

@MainActor
@Observable
public final class DOMNodeModel: Equatable, Hashable {
    public struct ID: Hashable, Sendable {
        public let documentIdentity: UUID
        public let localID: UInt64

        public init(documentIdentity: UUID, localID: UInt64) {
            self.documentIdentity = documentIdentity
            self.localID = localID
        }
    }

    public let id: ID
    package var backendNodeID: Int?
    public var nodeType: Int
    public var nodeName: String
    public var localName: String
    public var nodeValue: String
    public var attributes: [DOMAttribute]

    public weak var parent: DOMNodeModel?
    public weak var previousSibling: DOMNodeModel?
    public weak var nextSibling: DOMNodeModel?
    public var children: [DOMNodeModel]

    public var childCount: Int
    public var layoutFlags: [String]
    public var isRendered: Bool
    public var styleRevision: Int
    public var preview: String
    public var path: [String]
    public var selectorPath: String

    package init(
        id: ID,
        backendNodeID: Int? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMAttribute],
        children: [DOMNodeModel] = [],
        childCount: Int,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        styleRevision: Int = 0,
        preview: String = "",
        path: [String] = [],
        selectorPath: String = ""
    ) {
        self.id = id
        self.backendNodeID = backendNodeID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.attributes = attributes
        self.children = children
        self.childCount = childCount
        self.layoutFlags = layoutFlags
        self.isRendered = isRendered
        self.styleRevision = styleRevision
        self.preview = preview
        self.path = path
        self.selectorPath = selectorPath
    }

    public var localID: UInt64 {
        id.localID
    }

    public nonisolated static func == (lhs: DOMNodeModel, rhs: DOMNodeModel) -> Bool {
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    package func clearSelectionProjectionState() {
        preview = ""
        path = []
        selectorPath = ""
        styleRevision = 0
    }
}
