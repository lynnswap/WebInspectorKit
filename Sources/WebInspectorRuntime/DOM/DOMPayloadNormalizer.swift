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
        resetDocument: Bool
    ) -> DOMGraphDelta? {
        guard let object = Self.dictionaryValue(from: data),
              let rootPayload = object["root"],
              let root = Self.normalizeNodeDescriptor(rootPayload)
        else {
            return nil
        }
        return .snapshot(.init(root: root), resetDocument: resetDocument)
    }

    func normalizeDOMEvent(
        method rawMethod: String,
        paramsData: Data
    ) -> DOMGraphDelta? {
        let params = Self.dictionaryValue(from: paramsData) ?? [:]
        let method = rawMethod.hasPrefix("DOM.") ? String(rawMethod.dropFirst(4)) : rawMethod
        guard let event = Self.normalizeMutationEvent(method: method, params: params) else {
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
        params: [String: Any]
    ) -> DOMGraphMutationEvent? {
        switch method {
        case "childNodeInserted":
            guard let parentLocalID = uint64Value(params["parentNodeId"]),
                  let nodePayload = params["node"],
                  let node = normalizeNodeDescriptor(nodePayload)
            else {
                return nil
            }
            let previousLocalID = uint64ValueAllowingZero(params["previousNodeId"])
            return .childNodeInserted(
                parentLocalID: parentLocalID,
                previousLocalID: previousLocalID,
                node: node
            )

        case "childNodeRemoved":
            guard let parentLocalID = uint64Value(params["parentNodeId"]),
                  let nodeLocalID = uint64Value(params["nodeId"]) else {
                return nil
            }
            return .childNodeRemoved(parentLocalID: parentLocalID, nodeLocalID: nodeLocalID)

        case "shadowRootPushed":
            guard let hostLocalID = uint64Value(params["hostId"]),
                  let rootPayload = params["root"],
                  let root = normalizeNodeDescriptor(rootPayload)
            else {
                return nil
            }
            return .shadowRootPushed(hostLocalID: hostLocalID, root: root)

        case "shadowRootPopped":
            guard let hostLocalID = uint64Value(params["hostId"]),
                  let rootLocalID = uint64Value(params["rootId"]) else {
                return nil
            }
            return .shadowRootPopped(hostLocalID: hostLocalID, rootLocalID: rootLocalID)

        case "pseudoElementAdded":
            guard let parentLocalID = uint64Value(params["parentId"]),
                  let nodePayload = params["pseudoElement"],
                  let node = normalizeNodeDescriptor(nodePayload)
            else {
                return nil
            }
            return .pseudoElementAdded(parentLocalID: parentLocalID, node: node)

        case "pseudoElementRemoved":
            guard let parentLocalID = uint64Value(params["parentId"]),
                  let nodeLocalID = uint64Value(params["pseudoElementId"]) else {
                return nil
            }
            return .pseudoElementRemoved(parentLocalID: parentLocalID, nodeLocalID: nodeLocalID)

        case "attributeModified":
            guard let nodeLocalID = uint64Value(params["nodeId"]),
                  let name = stringValue(params["name"]) else {
                return nil
            }
            return .attributeModified(
                nodeLocalID: nodeLocalID,
                name: name,
                value: stringValue(params["value"]) ?? "",
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "attributeRemoved":
            guard let nodeLocalID = uint64Value(params["nodeId"]),
                  let name = stringValue(params["name"]) else {
                return nil
            }
            return .attributeRemoved(
                nodeLocalID: nodeLocalID,
                name: name,
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "characterDataModified":
            guard let nodeLocalID = uint64Value(params["nodeId"]) else {
                return nil
            }
            return .characterDataModified(
                nodeLocalID: nodeLocalID,
                value: stringValue(params["characterData"]) ?? "",
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "childNodeCountUpdated":
            guard let nodeLocalID = uint64Value(params["nodeId"]),
                  let childCount = intValue(params["childNodeCount"]) else {
                return nil
            }
            return .childNodeCountUpdated(
                nodeLocalID: nodeLocalID,
                childCount: childCount,
                layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                isRendered: boolValue(params["isRendered"])
            )

        case "setChildNodes":
            let nodesPayload = arrayValue(params["nodes"]) ?? []
            let nodes = nodesPayload.compactMap(normalizeNodeDescriptor)
            if let parentLocalID = uint64Value(params["parentId"]) {
                return .setChildNodes(parentLocalID: parentLocalID, nodes: nodes)
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

    static func normalizeNodeDescriptor(_ payload: Any) -> DOMGraphNodeDescriptor? {
        guard let object = dictionaryValue(payload),
              let localID = uint64Value(object["nodeId"])
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
        let explicitBackendNodeID = intValue(object["backendNodeId"])
        let backendNodeID = explicitBackendNodeID
            ?? (localID <= UInt64(Int.max) ? Int(localID) : nil)

        let pseudoType = stringValue(object["pseudoType"])
        let shadowRootType = stringValue(object["shadowRootType"])

        let hasRegularChildrenPayload = object["children"] != nil
        let regularChildPayloads = arrayValue(object["children"]) ?? []
        let (regularChildren, omittedRegularChildren) = normalizeNodeDescriptorArray(regularChildPayloads)
        let contentDocument = dictionaryValue(object["contentDocument"]).flatMap(normalizeNodeDescriptor)
        let (shadowRoots, _) = normalizeNodeDescriptorArray(arrayValue(object["shadowRoots"]) ?? [])
        let templateContent = dictionaryValue(object["templateContent"]).flatMap(normalizeNodeDescriptor)

        let pseudoElements = (arrayValue(object["pseudoElements"]) ?? []).compactMap(normalizeNodeDescriptor)
        let beforePseudoElement = pseudoElements.first { $0.pseudoType == "before" }
        let afterPseudoElement = pseudoElements.first { $0.pseudoType == "after" }

        let explicitChildCount = intValue(object["childNodeCount"])
        let childCountIsKnown = explicitChildCount != nil
            || contentDocument != nil
            || hasRegularChildrenPayload
        let childCount: Int
        if contentDocument != nil {
            childCount = 1
        } else if hasRegularChildrenPayload {
            childCount = regularChildren.count
        } else if let explicitChildCount {
            childCount = max(0, explicitChildCount - omittedRegularChildren)
        } else {
            childCount = 0
        }

        return DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: backendNodeID,
            backendNodeIDIsStable: explicitBackendNodeID != nil,
            frameID: frameID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: normalizeNodeAttributes(object["attributes"], backendNodeID: backendNodeID),
            childCount: childCount,
            childCountIsKnown: childCountIsKnown,
            layoutFlags: normalizeLayoutFlags(object["layoutFlags"]) ?? [],
            isRendered: boolValue(object["isRendered"]) ?? true,
            regularChildren: regularChildren,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement
        )
    }

    static func normalizeNodeDescriptorArray(
        _ payloads: [Any]
    ) -> (nodes: [DOMGraphNodeDescriptor], omittedInternalOverlayNodes: Int) {
        var nodes: [DOMGraphNodeDescriptor] = []
        nodes.reserveCapacity(payloads.count)
        var omittedInternalOverlayNodes = 0
        for payload in payloads {
            guard let node = normalizeNodeDescriptor(payload) else {
                if isInternalOverlayNodePayload(payload) {
                    omittedInternalOverlayNodes += 1
                }
                continue
            }
            nodes.append(node)
        }
        return (nodes, omittedInternalOverlayNodes)
    }

    static func normalizeNodeAttributes(_ payload: Any?, backendNodeID: Int?) -> [DOMAttribute] {
        guard let values = arrayValue(payload) else {
            return []
        }

        var attributes: [DOMAttribute] = []
        attributes.reserveCapacity(values.count / 2)
        var index = 0
        while index + 1 < values.count {
            let name = stringValue(values[index]) ?? ""
            let value = stringValue(values[index + 1]) ?? ""
            attributes.append(DOMAttribute(nodeId: backendNodeID, name: name, value: value))
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
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64, value > 0 {
            return value
        }
        if let value = value as? UInt, value > 0 {
            return UInt64(value)
        }
        guard let intValue = intValue(value), intValue > 0 else {
            return nil
        }
        return UInt64(intValue)
    }

    static func uint64ValueAllowingZero(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? UInt {
            return UInt64(value)
        }
        guard let intValue = intValue(value), intValue >= 0 else {
            return nil
        }
        return UInt64(intValue)
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
