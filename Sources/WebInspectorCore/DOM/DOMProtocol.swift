import WebInspectorTransport

package enum DOMAction {}
package enum DOMCommand {}

package extension DOMDocument {
    struct LifetimeID: RawRepresentable, Hashable, Comparable, Codable, Sendable {
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

    struct ID: Hashable, Sendable {
        package var targetID: ProtocolTarget.ID
        package var localDocumentLifetimeID: LifetimeID

        /// Local handle used for snapshots and node identity. This is not a
        /// protocol identity and must not be used for target/frame discovery.
        package init(targetID: ProtocolTarget.ID, localDocumentLifetimeID: LifetimeID) {
            self.targetID = targetID
            self.localDocumentLifetimeID = localDocumentLifetimeID
        }

        package var generation: LifetimeID {
            localDocumentLifetimeID
        }
    }
}

package extension DOMNode {
    struct ProtocolID: RawRepresentable, Hashable, Codable, Sendable {
        package let rawValue: Int

        package init(_ rawValue: Int) {
            self.rawValue = rawValue
        }

        package init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    struct ID: Hashable, Sendable {
        package var documentID: DOMDocument.ID
        package var nodeID: ProtocolID

        package init(documentID: DOMDocument.ID, nodeID: ProtocolID) {
            self.documentID = documentID
            self.nodeID = nodeID
        }
    }

    struct CurrentKey: Hashable, Sendable {
        package var targetID: ProtocolTarget.ID
        package var nodeID: ProtocolID

        package init(targetID: ProtocolTarget.ID, nodeID: ProtocolID) {
            self.targetID = targetID
            self.nodeID = nodeID
        }
    }

    enum RequestResolution: Equatable, Sendable {
        case resolved(ID)
        case pending(CurrentKey)
        case failed(DOMSelection.Failure)

        package func get() throws -> ID {
            switch self {
            case let .resolved(nodeID):
                return nodeID
            case let .pending(key):
                throw DOMSelection.Failure.unresolvedNode(key)
            case let .failed(failure):
                throw failure
            }
        }
    }

    enum Kind: Int, Equatable, Sendable {
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

    struct Attribute: Equatable, Hashable, Sendable {
        package var name: String
        package var value: String

        package init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    enum ChildrenPayload: Equatable, Sendable {
        case unrequested(count: Int)
        case loaded([Payload])
    }

    struct Payload: Equatable, Sendable {
        package var nodeID: ProtocolID
        package var nodeType: Kind
        package var nodeName: String
        package var localName: String
        package var nodeValue: String
        package var ownerFrameID: DOMFrame.ID?
        package var documentURL: String?
        package var baseURL: String?
        package var attributes: [Attribute]
        package var regularChildren: ChildrenPayload
        package var contentDocument: [Payload]
        package var shadowRoots: [Payload]
        package var templateContent: [Payload]
        package var beforePseudoElement: [Payload]
        package var otherPseudoElements: [Payload]
        package var afterPseudoElement: [Payload]
        package var pseudoType: String?
        package var shadowRootType: String?

        package init(
            nodeID: ProtocolID,
            nodeType: Kind,
            nodeName: String,
            localName: String = "",
            nodeValue: String = "",
            ownerFrameID: DOMFrame.ID? = nil,
            documentURL: String? = nil,
            baseURL: String? = nil,
            attributes: [Attribute] = [],
            regularChildren: ChildrenPayload = .unrequested(count: 0),
            contentDocument: Payload? = nil,
            shadowRoots: [Payload] = [],
            templateContent: Payload? = nil,
            beforePseudoElement: Payload? = nil,
            otherPseudoElements: [Payload] = [],
            afterPseudoElement: Payload? = nil,
            pseudoType: String? = nil,
            shadowRootType: String? = nil
        ) {
            self.nodeID = nodeID
            self.nodeType = nodeType
            self.nodeName = nodeName
            self.localName = localName
            self.nodeValue = nodeValue
            self.ownerFrameID = ownerFrameID
            self.documentURL = documentURL
            self.baseURL = baseURL
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

    enum CopyTextKind: Equatable, Sendable {
        case html
        case selectorPath
        case xPath
    }
}

package extension DOMTransaction {
    struct ID: RawRepresentable, Hashable, Codable, Sendable {
        package let rawValue: UInt64

        package init(_ rawValue: UInt64) {
            self.rawValue = rawValue
        }

        package init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    enum Kind: Equatable, Sendable {
        case requestChildNodes(parentRawNodeID: DOMNode.ProtocolID)
        case requestNode(selectionRequestID: DOMSelection.Request.ID, objectID: String)
        case ownerHydration(frameTargetID: ProtocolTarget.ID)
    }
}

package extension DOMCommand {
    enum NodeID: Equatable, Hashable, Sendable {
        case protocolNode(DOMNode.ProtocolID)

        /// WebInspectorUI represents frame-owned DOM nodes as
        /// `<frame target identifier>:<raw node id>` and sends that identifier to
        /// the page DOM agent for node-editing commands that FrameDOMAgent stubs.
        /// See WebKit's `DOMNode.js` `constructor`, `getOuterHTML`, and `removeNode`.
        case scoped(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID)

        package var rawProtocolNodeID: DOMNode.ProtocolID {
            switch self {
            case let .protocolNode(nodeID),
                 let .scoped(_, nodeID):
                return nodeID
            }
        }
    }

    enum Intent: Equatable, Sendable {
        case getDocument(targetID: ProtocolTarget.ID)
        case requestChildNodes(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID, depth: Int)
        case requestNode(selectionRequestID: DOMSelection.Request.ID, targetID: ProtocolTarget.ID, objectID: String)
        case highlightNode(identity: DOMAction.Identity)
        case hideHighlight(targetID: ProtocolTarget.ID)
        case setInspectModeEnabled(targetID: ProtocolTarget.ID, enabled: Bool)
        case getOuterHTML(identity: DOMAction.Identity)
        case removeNode(identity: DOMAction.Identity)
        case undo(targetID: ProtocolTarget.ID)
        case redo(targetID: ProtocolTarget.ID)
    }
}

package extension DOMAction {
    struct Identity: Equatable, Hashable, Sendable {
        package var documentTargetID: ProtocolTarget.ID
        package var rawNodeID: DOMNode.ProtocolID
        package var commandTargetID: ProtocolTarget.ID
        package var commandNodeID: DOMCommand.NodeID

        package init(
            documentTargetID: ProtocolTarget.ID,
            rawNodeID: DOMNode.ProtocolID,
            commandTargetID: ProtocolTarget.ID,
            commandNodeID: DOMCommand.NodeID
        ) {
            self.documentTargetID = documentTargetID
            self.rawNodeID = rawNodeID
            self.commandTargetID = commandTargetID
            self.commandNodeID = commandNodeID
        }
    }
}

package enum DOMInspectEvent: Equatable, Sendable {
    package struct RemoteObject: Equatable, Sendable {
        package var objectID: String
        package var injectedScriptID: RuntimeContext.ID?

        package init(objectID: String, injectedScriptID: RuntimeContext.ID?) {
            self.objectID = objectID
            self.injectedScriptID = injectedScriptID
        }
    }

    case remoteObject(targetID: ProtocolTarget.ID?, remoteObject: RemoteObject)
    case protocolNode(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID)
}

package extension DOMSelection {
    struct Request: Equatable, Sendable {
        package struct ID: RawRepresentable, Hashable, Sendable {
            package let rawValue: UInt64

            package init(_ rawValue: UInt64) {
                self.rawValue = rawValue
            }

            package init(rawValue: UInt64) {
                self.rawValue = rawValue
            }
        }

        package var id: ID
        package var targetID: ProtocolTarget.ID
        package var documentID: DOMDocument.ID
        package var transactionID: DOMTransaction.ID?
    }

    enum Failure: Swift.Error, Equatable, Sendable {
        case missingObjectID
        case missingInjectedScriptID
        case unknownExecutionContext(RuntimeContext.ID)
        case missingCurrentDocument(ProtocolTarget.ID)
        case staleSelectionRequest(expected: Request.ID?, received: Request.ID)
        case targetMismatch(expected: ProtocolTarget.ID, received: ProtocolTarget.ID)
        case staleDocument(expected: DOMDocument.ID, actual: DOMDocument.ID?)
        case unresolvedNode(DOMNode.CurrentKey)
    }
}
