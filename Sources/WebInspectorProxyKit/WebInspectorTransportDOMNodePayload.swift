import Foundation

final class WebInspectorTransportDOMNodePayload: Decodable {
    var nodeId: String
    var nodeType: Int
    var nodeName: String
    var localName: String
    var nodeValue: String
    var frameId: String?
    var childNodeCount: Int?
    var children: [WebInspectorTransportDOMNodePayload]?
    var attributes: [String]?
    var documentURL: String?
    var baseURL: String?
    var pseudoType: String?
    var shadowRootType: String?
    var contentDocument: WebInspectorTransportDOMNodePayload?
    var shadowRoots: [WebInspectorTransportDOMNodePayload]?
    var templateContent: WebInspectorTransportDOMNodePayload?
    var pseudoElements: [WebInspectorTransportDOMNodePayload]?

    private enum CodingKeys: String, CodingKey {
        case nodeId
        case nodeType
        case nodeName
        case localName
        case nodeValue
        case frameId
        case childNodeCount
        case children
        case attributes
        case documentURL
        case baseURL
        case pseudoType
        case shadowRootType
        case contentDocument
        case shadowRoots
        case templateContent
        case pseudoElements
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeStringOrInteger(forKey: .nodeId)
        nodeType = try container.decode(Int.self, forKey: .nodeType)
        nodeName = try container.decode(String.self, forKey: .nodeName)
        localName = try container.decode(String.self, forKey: .localName)
        nodeValue = try container.decode(String.self, forKey: .nodeValue)
        frameId = try container.decodeIfPresent(String.self, forKey: .frameId)
        childNodeCount = try container.decodeIfPresent(Int.self, forKey: .childNodeCount)
        children = try container.decodeIfPresent([WebInspectorTransportDOMNodePayload].self, forKey: .children)
        attributes = try container.decodeIfPresent([String].self, forKey: .attributes)
        documentURL = try container.decodeIfPresent(String.self, forKey: .documentURL)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        pseudoType = try container.decodeIfPresent(String.self, forKey: .pseudoType)
        shadowRootType = try container.decodeIfPresent(String.self, forKey: .shadowRootType)
        contentDocument = try container.decodeIfPresent(WebInspectorTransportDOMNodePayload.self, forKey: .contentDocument)
        shadowRoots = try container.decodeIfPresent([WebInspectorTransportDOMNodePayload].self, forKey: .shadowRoots)
        templateContent = try container.decodeIfPresent(WebInspectorTransportDOMNodePayload.self, forKey: .templateContent)
        pseudoElements = try container.decodeIfPresent([WebInspectorTransportDOMNodePayload].self, forKey: .pseudoElements)
    }

    func proxyNode() throws -> DOM.Node {
        let pseudoElements = try (pseudoElements ?? []).map { try $0.proxyNode() }
        return DOM.Node(
            id: DOM.Node.ID(nodeId),
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            frameID: frameId.map(FrameID.init),
            documentURL: documentURL,
            baseURL: baseURL,
            attributes: try attributeDictionary(),
            childNodeCount: childNodeCount ?? 0,
            children: try children?.map { try $0.proxyNode() },
            contentDocument: try contentDocument?.proxyNode(),
            shadowRoots: try (shadowRoots ?? []).map { try $0.proxyNode() },
            templateContent: try templateContent?.proxyNode(),
            beforePseudoElement: pseudoElements.first { $0.pseudoType?.isBefore == true },
            otherPseudoElements: pseudoElements.filter { $0.pseudoType?.isBefore != true && $0.pseudoType?.isAfter != true },
            afterPseudoElement: pseudoElements.first { $0.pseudoType?.isAfter == true },
            pseudoType: Self.pseudoType(pseudoType),
            shadowRootType: Self.shadowRootType(shadowRootType)
        )
    }

    private func attributeDictionary() throws -> [String: String] {
        guard let attributes else {
            return [:]
        }
        guard attributes.count.isMultiple(of: 2) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.attributes],
                debugDescription: "DOM.Node attributes must be an even flat name/value array."
            ))
        }
        var result: [String: String] = [:]
        result.reserveCapacity(attributes.count / 2)
        for index in stride(from: 0, to: attributes.count, by: 2) {
            result[attributes[index]] = attributes[index + 1]
        }
        return result
    }

    private static func pseudoType(_ value: String?) -> DOM.PseudoType? {
        switch value {
        case nil:
            nil
        case "before":
            .before
        case "after":
            .after
        case let .some(value):
            .other(value)
        }
    }

    private static func shadowRootType(_ value: String?) -> DOM.ShadowRootType? {
        switch value {
        case nil:
            nil
        case "open":
            .open
        case "closed":
            .closed
        case "user-agent":
            .userAgent
        case let .some(value):
            .other(value)
        }
    }
}

extension DOM.PseudoType {
    var isBefore: Bool {
        if case .before = self {
            return true
        }
        return false
    }

    var isAfter: Bool {
        if case .after = self {
            return true
        }
        return false
    }
}
