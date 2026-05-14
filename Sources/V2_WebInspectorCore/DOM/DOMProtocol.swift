package struct DOMProtocolNodeID: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: Int

    package init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

package struct DOMDocumentGeneration: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    package let rawValue: UInt64

    package init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct DOMDocumentIdentifier: Hashable, Sendable {
    package var targetID: ProtocolTargetIdentifier
    package var generation: DOMDocumentGeneration

    package init(targetID: ProtocolTargetIdentifier, generation: DOMDocumentGeneration) {
        self.targetID = targetID
        self.generation = generation
    }
}

package struct DOMNodeIdentifier: Hashable, Sendable {
    package var documentID: DOMDocumentIdentifier
    package var nodeID: DOMProtocolNodeID

    package init(documentID: DOMDocumentIdentifier, nodeID: DOMProtocolNodeID) {
        self.documentID = documentID
        self.nodeID = nodeID
    }
}

package struct DOMNodeCurrentKey: Hashable, Sendable {
    package var targetID: ProtocolTargetIdentifier
    package var nodeID: DOMProtocolNodeID

    package init(targetID: ProtocolTargetIdentifier, nodeID: DOMProtocolNodeID) {
        self.targetID = targetID
        self.nodeID = nodeID
    }
}

package enum DOMNodeType: Int, Equatable, Sendable {
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
}

package struct DOMAttribute: Equatable, Hashable, Sendable {
    package var name: String
    package var value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

package enum DOMRegularChildrenPayload: Equatable, Sendable {
    case unrequested(count: Int)
    case loaded([DOMNodePayload])
}

package struct DOMNodePayload: Equatable, Sendable {
    package var nodeID: DOMProtocolNodeID
    package var nodeType: DOMNodeType
    package var nodeName: String
    package var localName: String
    package var nodeValue: String
    package var frameID: DOMFrameIdentifier?
    package var attributes: [DOMAttribute]
    package var regularChildren: DOMRegularChildrenPayload
    package var contentDocument: [DOMNodePayload]
    package var shadowRoots: [DOMNodePayload]
    package var templateContent: [DOMNodePayload]
    package var beforePseudoElement: [DOMNodePayload]
    package var otherPseudoElements: [DOMNodePayload]
    package var afterPseudoElement: [DOMNodePayload]
    package var pseudoType: String?
    package var shadowRootType: String?

    package init(
        nodeID: DOMProtocolNodeID,
        nodeType: DOMNodeType,
        nodeName: String,
        localName: String = "",
        nodeValue: String = "",
        frameID: DOMFrameIdentifier? = nil,
        attributes: [DOMAttribute] = [],
        regularChildren: DOMRegularChildrenPayload = .unrequested(count: 0),
        contentDocument: DOMNodePayload? = nil,
        shadowRoots: [DOMNodePayload] = [],
        templateContent: DOMNodePayload? = nil,
        beforePseudoElement: DOMNodePayload? = nil,
        otherPseudoElements: [DOMNodePayload] = [],
        afterPseudoElement: DOMNodePayload? = nil,
        pseudoType: String? = nil,
        shadowRootType: String? = nil
    ) {
        self.nodeID = nodeID
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.frameID = frameID
        self.attributes = attributes
        self.regularChildren = regularChildren
        self.contentDocument = contentDocument.map { [$0] } ?? []
        self.shadowRoots = shadowRoots
        self.templateContent = templateContent.map { [$0] } ?? []
        self.beforePseudoElement = beforePseudoElement.map { [$0] } ?? []
        self.otherPseudoElements = otherPseudoElements
        self.afterPseudoElement = afterPseudoElement.map { [$0] } ?? []
        self.pseudoType = pseudoType
        self.shadowRootType = shadowRootType
    }
}

package struct RemoteObject: Equatable, Sendable {
    package var objectID: String
    package var injectedScriptID: ExecutionContextID?

    package init(objectID: String, injectedScriptID: ExecutionContextID?) {
        self.objectID = objectID
        self.injectedScriptID = injectedScriptID
    }
}

package struct SelectionRequestIdentifier: RawRepresentable, Hashable, Sendable {
    package let rawValue: UInt64

    package init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package enum DOMCommandIntent: Equatable, Sendable {
    case getDocument(targetID: ProtocolTargetIdentifier)
    case requestChildNodes(targetID: ProtocolTargetIdentifier, nodeID: DOMProtocolNodeID, depth: Int)
    case requestNode(selectionRequestID: SelectionRequestIdentifier, targetID: ProtocolTargetIdentifier, objectID: String)
    case highlightNode(targetID: ProtocolTargetIdentifier, nodeID: DOMProtocolNodeID)
    case hideHighlight(targetID: ProtocolTargetIdentifier)
}

package enum SelectionResolutionFailure: Error, Equatable, Sendable {
    case missingObjectID
    case missingInjectedScriptID
    case unknownExecutionContext(ExecutionContextID)
    case missingCurrentDocument(ProtocolTargetIdentifier)
    case staleSelectionRequest(expected: SelectionRequestIdentifier?, received: SelectionRequestIdentifier)
    case targetMismatch(expected: ProtocolTargetIdentifier, received: ProtocolTargetIdentifier)
    case staleDocument(expected: DOMDocumentIdentifier, actual: DOMDocumentIdentifier?)
    case unresolvedNode(DOMNodeCurrentKey)
}
