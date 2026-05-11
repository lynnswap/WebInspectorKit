import Foundation
import WebInspectorEngine

enum DOMGraphDelta: Sendable {
    case snapshot(DOMGraphSnapshot, resetDocument: Bool)
    case mutations(DOMGraphMutationBundle)
    case selection(DOMSelectionSnapshotPayload?)
    case selectorPath(DOMSelectorPathPayload)
}

actor DOMPayloadNormalizer {
    nonisolated func resetForDocumentUpdate() {}

    func documentURL(fromDocumentResponseData data: Data) -> String? {
        guard let object = Self.dictionaryValue(from: data),
              let root = Self.dictionaryValue(object["root"]) else {
            return nil
        }
        return Self.stringValue(root["documentURL"])
    }

    func normalizeDocumentResponseData(
        _ data: Data,
        targetIdentifier: String,
        resetDocument: Bool
    ) -> DOMGraphDelta? {
        guard let object = Self.dictionaryValue(from: data),
              let rootPayload = object["root"],
              let root = Self.normalizeNodeDescriptor(rootPayload, targetIdentifier: targetIdentifier)
        else {
            return nil
        }
        return .snapshot(.init(root: root), resetDocument: resetDocument)
    }

    func normalizeDOMEvent(
        method rawMethod: String,
        targetIdentifier: String,
        paramsData: Data
    ) -> DOMGraphDelta? {
        let params = Self.dictionaryValue(from: paramsData) ?? [:]
        let method = rawMethod.hasPrefix("DOM.") ? String(rawMethod.dropFirst(4)) : rawMethod
        guard let event = Self.normalizeMutationEvent(
            method: method,
            targetIdentifier: targetIdentifier,
            params: params
        ) else {
            return nil
        }
        return .mutations(.init(events: [event]))
    }

}

private extension DOMPayloadNormalizer {
    static func dictionaryValue(from data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return object as? [String: Any]
    }

    static func normalizeMutationEvent(
        method: String,
        targetIdentifier: String,
        params: [String: Any]
    ) -> DOMGraphMutationEvent? {
        switch method {
        case "childNodeInserted":
            guard let parentNodeID = nodeIDValue(params["parentNodeId"]),
                  let nodePayload = params["node"],
                  let node = normalizeNodeDescriptor(nodePayload, targetIdentifier: targetIdentifier)
            else {
                return nil
            }
            let previousSibling: DOMGraphPreviousSibling
            if let rawPreviousNodeID = params["previousNodeId"] {
                guard let previousNodeID = nodeIDValueAllowingZero(rawPreviousNodeID) else {
                    return nil
                }
                previousSibling = previousNodeID == 0
                    ? .firstChild
                    : .node(DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: previousNodeID))
            } else {
                previousSibling = .missing
            }
            return .childNodeInserted(
                parentKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: parentNodeID),
                previousSibling: previousSibling,
                node: node
            )

        case "childNodeRemoved":
            guard let parentNodeID = nodeIDValue(params["parentNodeId"]),
                  let nodeID = nodeIDValue(params["nodeId"]) else {
                return nil
            }
            return .childNodeRemoved(
                parentKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: parentNodeID),
                nodeKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID)
            )

        case "shadowRootPushed":
            guard let hostNodeID = nodeIDValue(params["hostId"]),
                  let rootPayload = params["root"],
                  let root = normalizeNodeDescriptor(rootPayload, targetIdentifier: targetIdentifier)
            else {
                return nil
            }
            return .shadowRootPushed(
                hostKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: hostNodeID),
                root: root
            )

        case "shadowRootPopped":
            guard let hostNodeID = nodeIDValue(params["hostId"]),
                  let rootNodeID = nodeIDValue(params["rootId"]) else {
                return nil
            }
            return .shadowRootPopped(
                hostKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: hostNodeID),
                rootKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: rootNodeID)
            )

        case "pseudoElementAdded":
            guard let parentNodeID = nodeIDValue(params["parentId"]),
                  let nodePayload = params["pseudoElement"],
                  let node = normalizeNodeDescriptor(nodePayload, targetIdentifier: targetIdentifier)
            else {
                return nil
            }
            return .pseudoElementAdded(
                parentKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: parentNodeID),
                node: node
            )

        case "pseudoElementRemoved":
            guard let parentNodeID = nodeIDValue(params["parentId"]),
                  let nodeID = nodeIDValue(params["pseudoElementId"]) else {
                return nil
            }
            return .pseudoElementRemoved(
                parentKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: parentNodeID),
                nodeKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID)
            )

        case "attributeModified":
            guard let nodeID = nodeIDValue(params["nodeId"]),
                  let name = stringValue(params["name"]) else {
                return nil
            }
            return .attributeModified(
                nodeKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID),
                name: name,
                value: stringValue(params["value"]) ?? "",
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "attributeRemoved":
            guard let nodeID = nodeIDValue(params["nodeId"]),
                  let name = stringValue(params["name"]) else {
                return nil
            }
            return .attributeRemoved(
                nodeKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID),
                name: name,
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "characterDataModified":
            guard let nodeID = nodeIDValue(params["nodeId"]) else {
                return nil
            }
            return .characterDataModified(
                nodeKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID),
                value: stringValue(params["characterData"]) ?? "",
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "childNodeCountUpdated":
            guard let nodeID = nodeIDValue(params["nodeId"]),
                  let childCount = intValue(params["childNodeCount"]) else {
                return nil
            }
            return .childNodeCountUpdated(
                nodeKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: nodeID),
                childCount: childCount,
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "setChildNodes":
            let nodesPayload = arrayValue(params["nodes"]) ?? []
            let nodes = normalizeNodeDescriptorArray(
                nodesPayload,
                targetIdentifier: targetIdentifier
            ).nodes
            if let parentNodeID = nodeIDValue(params["parentId"]) {
                return .setChildNodes(
                    parentKey: DOMNodeKey(targetIdentifier: targetIdentifier, nodeID: parentNodeID),
                    nodes: nodes
                )
            }
            guard !nodes.isEmpty else {
                return nil
            }
            return .setDetachedRoots(nodes: nodes)

        case "documentUpdated":
            return .documentUpdated

        default:
            return nil
        }
    }

    static func normalizeNodeDescriptor(_ payload: Any, targetIdentifier: String) -> DOMGraphNodeDescriptor? {
        guard let object = dictionaryValue(payload),
              let nodeID = nodeIDValue(object["nodeId"])
        else {
            return nil
        }

        if isInternalOverlayNodePayload(object) {
            return nil
        }

        let nodeType = DOMNodeType(protocolValue: intValue(object["nodeType"]) ?? 0)
        let rawNodeName = stringValue(object["nodeName"]) ?? ""
        let rawLocalName = stringValue(object["localName"]) ?? ""
        let frameID = stringValue(object["frameId"])
        let nodeName = nodeType == .element ? rawNodeName.lowercased() : rawNodeName
        let localName = nodeType == .element
            ? (rawLocalName.isEmpty ? rawNodeName : rawLocalName).lowercased()
            : rawLocalName
        let nodeValue = stringValue(object["nodeValue"]) ?? ""

        let pseudoType = stringValue(object["pseudoType"])
        let shadowRootType = stringValue(object["shadowRootType"])

        let hasRegularChildrenPayload = object["children"] != nil
        let regularChildPayloads = arrayValue(object["children"]) ?? []
        let (regularChildren, omittedRegularChildren) = normalizeNodeDescriptorArray(
            regularChildPayloads,
            targetIdentifier: targetIdentifier
        )
        let contentDocument = dictionaryValue(object["contentDocument"]).flatMap {
            normalizeNodeDescriptor($0, targetIdentifier: targetIdentifier)
        }
        let (shadowRoots, _) = normalizeNodeDescriptorArray(
            arrayValue(object["shadowRoots"]) ?? [],
            targetIdentifier: targetIdentifier
        )
        let templateContent = dictionaryValue(object["templateContent"]).flatMap {
            normalizeNodeDescriptor($0, targetIdentifier: targetIdentifier)
        }

        let pseudoElements = (arrayValue(object["pseudoElements"]) ?? []).compactMap {
            normalizeNodeDescriptor($0, targetIdentifier: targetIdentifier)
        }
        let beforePseudoElement = pseudoElements.first { $0.pseudoType == "before" }
        let afterPseudoElement = pseudoElements.first { $0.pseudoType == "after" }

        let explicitChildCount = intValue(object["childNodeCount"])
        let regularChildCount: Int
        if hasRegularChildrenPayload {
            regularChildCount = regularChildren.count
        } else if let explicitChildCount {
            let contentDocumentCount = contentDocument == nil ? 0 : 1
            regularChildCount = max(0, explicitChildCount - contentDocumentCount - omittedRegularChildren)
        } else {
            regularChildCount = nodeType.canRequestRegularChildren ? 1 : 0
        }

        return DOMGraphNodeDescriptor(
            targetIdentifier: targetIdentifier,
            nodeID: nodeID,
            frameID: frameID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: normalizeNodeAttributes(object["attributes"], nodeID: nodeID),
            regularChildCount: regularChildCount,
            regularChildrenAreLoaded: hasRegularChildrenPayload,
            layoutFlags: normalizeLayoutFlags(object["layoutFlags"]) ?? [],
            isRendered: boolValue(object["isRendered"]) ?? true,
            regularChildren: hasRegularChildrenPayload ? regularChildren : nil,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement
        )
    }

    static func normalizeNodeDescriptorArray(
        _ payloads: [Any],
        targetIdentifier: String
    ) -> (nodes: [DOMGraphNodeDescriptor], omittedInternalOverlayNodes: Int) {
        var nodes: [DOMGraphNodeDescriptor] = []
        nodes.reserveCapacity(payloads.count)
        var omittedInternalOverlayNodes = 0
        for payload in payloads {
            guard let node = normalizeNodeDescriptor(payload, targetIdentifier: targetIdentifier) else {
                if isInternalOverlayNodePayload(payload) {
                    omittedInternalOverlayNodes += 1
                }
                continue
            }
            nodes.append(node)
        }
        return (nodes, omittedInternalOverlayNodes)
    }

    static func normalizeNodeAttributes(_ payload: Any?, nodeID: Int?) -> [DOMAttribute] {
        guard let values = arrayValue(payload) else {
            return []
        }

        var attributes: [DOMAttribute] = []
        attributes.reserveCapacity(values.count / 2)
        var index = 0
        while index + 1 < values.count {
            let name = stringValue(values[index]) ?? ""
            let value = stringValue(values[index + 1]) ?? ""
            attributes.append(DOMAttribute(nodeId: nodeID, name: name, value: value))
            index += 2
        }
        return attributes
    }

    static func containsInternalOverlayMarker(_ payload: Any?) -> Bool {
        guard let values = arrayValue(payload) else {
            return false
        }

        var index = 0
        while index + 1 < values.count {
            if stringValue(values[index]) == "data-web-inspector-overlay" {
                return stringValue(values[index + 1]) == "true"
            }
            index += 2
        }
        return false
    }

    static func isInternalOverlayNodePayload(_ payload: Any?) -> Bool {
        guard let object = dictionaryValue(payload) else {
            return false
        }
        return containsInternalOverlayMarker(object["attributes"])
    }

    static func normalizeLayoutFlags(_ payload: Any?) -> [String]? {
        guard let values = arrayValue(payload) else {
            return nil
        }
        return values.compactMap(stringValue)
    }

    static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] {
            return value
        }
        if let value = value as? NSDictionary {
            var result: [String: Any] = [:]
            result.reserveCapacity(value.count)
            for (rawKey, rawValue) in value {
                guard let key = rawKey as? String else {
                    return nil
                }
                result[key] = rawValue
            }
            return result
        }
        return nil
    }

    static func arrayValue(_ value: Any?) -> [Any]? {
        if let value = value as? [Any] {
            return value
        }
        if let value = value as? NSArray {
            return value.map { $0 }
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        if value is NSNull {
            return nil
        }
        if let value = value as? String {
            return value
        }
        if let value = value as? NSString {
            return String(value)
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = value.doubleValue
            guard doubleValue.isFinite else {
                return nil
            }
            let truncated = doubleValue.rounded(.towardZero)
            guard truncated == doubleValue else {
                return nil
            }
            guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
                return nil
            }
            return Int(truncated)
        }
        if value is Bool {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? UInt64 {
            guard value <= UInt64(Int.max) else {
                return nil
            }
            return Int(value)
        }
        if let value = value as? UInt {
            guard value <= UInt(Int.max) else {
                return nil
            }
            return Int(value)
        }
        if let value = value as? Int64 {
            guard value >= Int64(Int.min), value <= Int64(Int.max) else {
                return nil
            }
            return Int(value)
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    static func nodeIDValue(_ value: Any?) -> Int? {
        guard let intValue = intValue(value), intValue > 0 else {
            return nil
        }
        return intValue
    }

    static func nodeIDValueAllowingZero(_ value: Any?) -> Int? {
        guard let intValue = intValue(value), intValue >= 0 else {
            return nil
        }
        return intValue
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
            return value.intValue != 0
        }
        return nil
    }
}

private extension DOMNodeType {
    var canRequestRegularChildren: Bool {
        switch self {
        case .element, .document, .documentFragment:
            return true
        default:
            return false
        }
    }
}
