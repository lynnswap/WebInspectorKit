import Foundation
import WebInspectorEngine

enum DOMGraphDelta {
    case snapshot(DOMGraphSnapshot, resetDocument: Bool)
    case mutations(DOMGraphMutationBundle)
    case replaceSubtree(DOMGraphNodeDescriptor)
    case selection(DOMSelectionSnapshotPayload?)
    case selectorPath(DOMSelectorPathPayload)
}

@MainActor
final class DOMPayloadNormalizer {
    nonisolated private static let fallbackLocalIDBase: UInt64 = 9_000_000_000_000_000_000
    private var nextFallbackLocalID: UInt64 = DOMPayloadNormalizer.fallbackLocalIDBase

    private struct FallbackState {
        var nextLocalID: UInt64

        mutating func allocate() -> UInt64 {
            let current = nextLocalID
            nextLocalID &+= 1
            return current
        }
    }

    func resetForDocumentUpdate() {
        nextFallbackLocalID = DOMPayloadNormalizer.fallbackLocalIDBase
    }

    func normalizeBundlePayload(_ payload: Any) -> DOMGraphDelta? {
        guard let object = parseObjectPayload(payload) else {
            return nil
        }

        if let version = intValue(object["version"]), version != 1 {
            return nil
        }

        switch stringValue(object["kind"]) {
        case "snapshot":
            let reason = stringValue(object["reason"])
            let shouldResetDocument = reason == "initial"
            if shouldResetDocument {
                resetForDocumentUpdate()
            }
            guard let snapshotPayload = object["snapshot"],
                  let snapshot = normalizeSnapshotPayload(snapshotPayload)
            else {
                return nil
            }
            return .snapshot(snapshot, resetDocument: shouldResetDocument)

        case "mutation":
            guard let events = arrayValue(object["events"]) else {
                return nil
            }
            let bundle = DOMGraphMutationBundle(events: normalizeMutationEvents(events))
            return .mutations(bundle)

        default:
            return nil
        }
    }

    func normalizeSelectionPayload(_ payload: Any) -> DOMGraphDelta {
        guard let object = dictionaryValue(payload), !object.isEmpty else {
            return .selection(nil)
        }

        let localID = uint64Value(object["id"]) ?? uint64Value(object["nodeId"])
        let preview = stringValue(object["preview"]) ?? ""
        let attributes = normalizeSelectionAttributes(object["attributes"], localID: localID)
        let path = arrayValue(object["path"])?.compactMap(stringValue) ?? []
        let selectorPath = stringValue(object["selectorPath"]) ?? ""
        let styleRevision = intValue(object["styleRevision"]) ?? 0

        let selection = DOMSelectionSnapshotPayload(
            localID: localID,
            preview: preview,
            attributes: attributes,
            path: path,
            selectorPath: selectorPath,
            styleRevision: styleRevision
        )
        return .selection(selection)
    }

    func normalizeSelectorPayload(_ payload: Any) -> DOMGraphDelta? {
        guard let object = dictionaryValue(payload) else {
            return nil
        }

        let localID = uint64Value(object["id"]) ?? uint64Value(object["nodeId"])
        let selectorPath = stringValue(object["selectorPath"]) ?? ""
        return .selectorPath(.init(localID: localID, selectorPath: selectorPath))
    }

    func normalizeProtocolResponse(
        method: String,
        responseObject: [String: Any],
        resetDocument: Bool
    ) -> DOMGraphDelta? {
        guard let result = responseObject["result"] else {
            return nil
        }

        switch method {
        case "DOM.getDocument":
            if resetDocument {
                resetForDocumentUpdate()
            }
            guard let snapshot = normalizeSnapshotPayload(result) else {
                return nil
            }
            return .snapshot(snapshot, resetDocument: resetDocument)

        case "DOM.requestChildNodes":
            var fallbackState = makeFallbackState()
            defer { commitFallbackState(fallbackState) }
            let normalizedPayload = resolveNodePayload(result) ?? result
            guard let node = normalizeNodeDescriptor(normalizedPayload, fallbackState: &fallbackState) else {
                return nil
            }
            return .replaceSubtree(node)

        default:
            return nil
        }
    }
}

private extension DOMPayloadNormalizer {
    private func makeFallbackState() -> FallbackState {
        FallbackState(nextLocalID: nextFallbackLocalID)
    }

    private func commitFallbackState(_ state: FallbackState) {
        nextFallbackLocalID = state.nextLocalID
    }

    func parseObjectPayload(_ payload: Any) -> [String: Any]? {
        if let object = dictionaryValue(payload) {
            return object
        }

        if let json = payload as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           let object = dictionaryValue(decoded) {
            return object
        }

        return nil
    }

    func normalizeSnapshotPayload(_ payload: Any) -> DOMGraphSnapshot? {
        guard let snapshotObject = resolveSnapshotPayload(payload) else {
            return nil
        }

        var fallbackState = makeFallbackState()
        defer { commitFallbackState(fallbackState) }
        guard let rootPayload = snapshotObject["root"],
              let root = normalizeNodeDescriptor(rootPayload, fallbackState: &fallbackState)
        else {
            return nil
        }

        let selectedLocalID = resolveSelectedLocalID(snapshotObject, root: root)
        return DOMGraphSnapshot(root: root, selectedLocalID: selectedLocalID)
    }

    func resolveSnapshotPayload(_ payload: Any) -> [String: Any]? {
        if let object = dictionaryValue(payload) {
            if isSerializedNodeEnvelope(object) {
                return resolveSerializedNodeEnvelope(object)
            }

            if object["root"] != nil {
                var resolved = object
                if let root = object["root"],
                   let rootObject = dictionaryValue(root),
                   isSerializedNodeEnvelope(rootObject),
                   let nested = resolveSerializedNodeEnvelope(rootObject),
                   let nestedRoot = nested["root"] {
                    resolved["root"] = nestedRoot
                    if resolved["selectedNodeId"] == nil {
                        resolved["selectedNodeId"] = nested["selectedNodeId"]
                    }
                    if resolved["selectedNodePath"] == nil {
                        resolved["selectedNodePath"] = nested["selectedNodePath"]
                    }
                }
                return resolved
            }

            if looksLikeNodeDescriptor(object) {
                return ["root": object]
            }
        }

        if let json = payload as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            return resolveSnapshotPayload(decoded)
        }

        return nil
    }

    func resolveSerializedNodeEnvelope(_ envelope: [String: Any]) -> [String: Any]? {
        guard isSerializedNodeEnvelope(envelope) else {
            return nil
        }

        let fallbackSnapshot = envelope["fallback"].flatMap(resolveSnapshotPayload)
        let rootFromNode = envelope["node"].flatMap(resolveNodePayload)
        let rootFromFallback = fallbackSnapshot?["root"] ?? envelope["fallback"].flatMap(resolveNodePayload)

        let resolvedRoot: Any?
        if let rootFromNode, let rootFromFallback {
            if nodeDescriptorHasStableIDs(rootFromNode) || !nodeDescriptorHasStableIDs(rootFromFallback) {
                resolvedRoot = rootFromNode
            } else {
                resolvedRoot = rootFromFallback
            }
        } else {
            resolvedRoot = rootFromNode ?? rootFromFallback
        }

        guard let resolvedRoot else {
            return fallbackSnapshot
        }

        var resolved: [String: Any] = ["root": resolvedRoot]
        if let selectedNodeID = uint64Value(envelope["selectedNodeId"]) ?? uint64Value(fallbackSnapshot?["selectedNodeId"]) {
            resolved["selectedNodeId"] = selectedNodeID
        }
        if let selectedNodePath = normalizeNodePath(envelope["selectedNodePath"]) ?? normalizeNodePath(fallbackSnapshot?["selectedNodePath"]) {
            resolved["selectedNodePath"] = selectedNodePath
        }
        return resolved
    }

    func resolveSelectedLocalID(_ snapshotObject: [String: Any], root: DOMGraphNodeDescriptor) -> UInt64? {
        if let selectedLocalID = uint64Value(snapshotObject["selectedNodeId"]) {
            return selectedLocalID
        }

        guard let path = normalizeNodePath(snapshotObject["selectedNodePath"]) else {
            return nil
        }

        var current = root
        for index in path {
            guard index >= 0, index < current.children.count else {
                return nil
            }
            current = current.children[index]
        }
        return current.localID
    }

    func resolveNodePayload(_ payload: Any) -> Any? {
        if let json = payload as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            return resolveNodePayload(decoded)
        }

        guard let object = dictionaryValue(payload) else {
            return nil
        }

        if isSerializedNodeEnvelope(object) {
            return resolveSerializedNodeEnvelope(object)?["root"]
        }

        return looksLikeNodeDescriptor(object) ? object : nil
    }

    private func normalizeNodeDescriptor(_ payload: Any, fallbackState: inout FallbackState) -> DOMGraphNodeDescriptor? {
        guard let object = dictionaryValue(payload) else {
            return nil
        }

        if isSerializedNodeEnvelope(object),
           let resolved = resolveSerializedNodeEnvelope(object),
           let root = resolved["root"] {
            return normalizeNodeDescriptor(root, fallbackState: &fallbackState)
        }

        let backendNodeID = intValue(object["nodeId"]) ?? intValue(object["id"])
        let localID = uint64Value(object["nodeId"]) ?? uint64Value(object["id"]) ?? fallbackState.allocate()
        let nodeType = intValue(object["nodeType"]) ?? 0
        let nodeName = stringValue(object["nodeName"]) ?? ""
        let localName = stringValue(object["localName"]) ?? ""
        let nodeValue = stringValue(object["nodeValue"]) ?? ""

        let attributes = normalizeNodeAttributes(object["attributes"], backendNodeID: backendNodeID)
        let childPayloads = arrayValue(object["children"]) ?? []
        let layoutFlags = normalizeLayoutFlags(object["layoutFlags"])
        let isRendered = boolValue(object["isRendered"]) ?? true

        var children: [DOMGraphNodeDescriptor] = []
        children.reserveCapacity(childPayloads.count)
        for childPayload in childPayloads {
            guard let child = normalizeNodeDescriptor(childPayload, fallbackState: &fallbackState) else {
                continue
            }
            children.append(child)
        }

        let childCount = intValue(object["childNodeCount"])
            ?? intValue(object["childCount"])
            ?? children.count

        return DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: backendNodeID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            childCount: max(0, childCount),
            layoutFlags: layoutFlags ?? [],
            isRendered: isRendered,
            children: children
        )
    }

    func normalizeMutationEvents(_ events: [Any]) -> [DOMGraphMutationEvent] {
        var normalized: [DOMGraphMutationEvent] = []
        var fallbackState = makeFallbackState()
        defer { commitFallbackState(fallbackState) }

        for entry in events {
            guard let object = dictionaryValue(entry) else {
                continue
            }
            guard let rawMethod = stringValue(object["method"]) else {
                continue
            }
            let method = rawMethod.hasPrefix("DOM.") ? String(rawMethod.dropFirst(4)) : rawMethod
            let params = dictionaryValue(object["params"]) ?? [:]

            switch method {
            case "childNodeInserted":
                guard let parentLocalID = uint64Value(params["parentNodeId"]) ?? uint64Value(params["parentId"]),
                      let nodePayload = params["node"],
                      let node = normalizeNodeDescriptor(nodePayload, fallbackState: &fallbackState)
                else {
                    continue
                }
                let previousLocalID = uint64ValueAllowingZero(params["previousNodeId"]) ?? uint64ValueAllowingZero(params["previousId"])
                normalized.append(
                    .childNodeInserted(
                        parentLocalID: parentLocalID,
                        previousLocalID: previousLocalID,
                        node: node
                    )
                )

            case "childNodeRemoved":
                guard let parentLocalID = uint64Value(params["parentNodeId"]) ?? uint64Value(params["parentId"]),
                      let nodeLocalID = uint64Value(params["nodeId"]) else {
                    continue
                }
                normalized.append(.childNodeRemoved(parentLocalID: parentLocalID, nodeLocalID: nodeLocalID))

            case "attributeModified":
                guard let nodeLocalID = uint64Value(params["nodeId"]),
                      let name = stringValue(params["name"])
                else {
                    continue
                }
                let value = stringValue(params["value"]) ?? ""
                normalized.append(
                    .attributeModified(
                        nodeLocalID: nodeLocalID,
                        name: name,
                        value: value,
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "attributeRemoved":
                guard let nodeLocalID = uint64Value(params["nodeId"]),
                      let name = stringValue(params["name"])
                else {
                    continue
                }
                normalized.append(
                    .attributeRemoved(
                        nodeLocalID: nodeLocalID,
                        name: name,
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "characterDataModified":
                guard let nodeLocalID = uint64Value(params["nodeId"]) else {
                    continue
                }
                normalized.append(
                    .characterDataModified(
                        nodeLocalID: nodeLocalID,
                        value: stringValue(params["characterData"]) ?? "",
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "childNodeCountUpdated":
                guard let nodeLocalID = uint64Value(params["nodeId"]),
                      let childCount = intValue(params["childNodeCount"]) ?? intValue(params["childCount"])
                else {
                    continue
                }
                normalized.append(
                    .childNodeCountUpdated(
                        nodeLocalID: nodeLocalID,
                        childCount: childCount,
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "setChildNodes":
                guard let parentLocalID = uint64Value(params["parentNodeId"]) ?? uint64Value(params["parentId"]) else {
                    continue
                }
                let nodesPayload = arrayValue(params["nodes"]) ?? []
                let nodes = nodesPayload.compactMap { normalizeNodeDescriptor($0, fallbackState: &fallbackState) }
                normalized.append(.setChildNodes(parentLocalID: parentLocalID, nodes: nodes))

            case "documentUpdated":
                normalized.append(.documentUpdated)
                fallbackState.nextLocalID = DOMPayloadNormalizer.fallbackLocalIDBase

            default:
                continue
            }
        }

        return normalized
    }

    func normalizeSelectionAttributes(_ payload: Any?, localID: UInt64?) -> [DOMAttribute] {
        let nodeID: Int?
        if let localID, localID <= UInt64(Int.max) {
            nodeID = Int(localID)
        } else {
            nodeID = nil
        }

        guard let values = arrayValue(payload) else {
            return []
        }

        return values.compactMap { entry in
            guard let object = dictionaryValue(entry),
                  let name = stringValue(object["name"])
            else {
                return nil
            }
            let value = stringValue(object["value"]) ?? ""
            return DOMAttribute(nodeId: nodeID, name: name, value: value)
        }
    }

    func normalizeNodeAttributes(_ payload: Any?, backendNodeID: Int?) -> [DOMAttribute] {
        guard let values = arrayValue(payload) else {
            return []
        }

        if values.allSatisfy({ $0 is String }) {
            var attributes: [DOMAttribute] = []
            var index = 0
            while index + 1 < values.count {
                let name = stringValue(values[index]) ?? ""
                let value = stringValue(values[index + 1]) ?? ""
                attributes.append(DOMAttribute(nodeId: backendNodeID, name: name, value: value))
                index += 2
            }
            return attributes
        }

        return values.compactMap { entry in
            guard let object = dictionaryValue(entry),
                  let name = stringValue(object["name"])
            else {
                return nil
            }
            let value = stringValue(object["value"]) ?? ""
            return DOMAttribute(nodeId: backendNodeID, name: name, value: value)
        }
    }

    func normalizeLayoutFlags(_ payload: Any?) -> [String]? {
        guard let values = arrayValue(payload) else {
            return nil
        }
        return values.compactMap(stringValue)
    }

    func normalizeNodePath(_ payload: Any?) -> [Int]? {
        guard let values = arrayValue(payload) else {
            return nil
        }
        var path: [Int] = []
        path.reserveCapacity(values.count)
        for value in values {
            guard let index = intValue(value), index >= 0 else {
                return nil
            }
            path.append(index)
        }
        return path
    }

    func isSerializedNodeEnvelope(_ object: [String: Any]) -> Bool {
        stringValue(object["type"]) == "serialized-node-envelope"
    }

    func looksLikeNodeDescriptor(_ object: [String: Any]) -> Bool {
        object["nodeId"] != nil
            || object["id"] != nil
            || object["nodeType"] != nil
            || object["nodeName"] != nil
            || object["children"] != nil
    }

    func nodeDescriptorHasStableIDs(_ payload: Any) -> Bool {
        guard let object = dictionaryValue(payload) else {
            return false
        }

        guard uint64Value(object["nodeId"]) != nil || uint64Value(object["id"]) != nil else {
            return false
        }

        guard let children = arrayValue(object["children"]) else {
            return true
        }

        for child in children {
            guard nodeDescriptorHasStableIDs(child) else {
                return false
            }
        }
        return true
    }

    func dictionaryValue(_ value: Any?) -> [String: Any]? {
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

    func arrayValue(_ value: Any?) -> [Any]? {
        if let value = value as? [Any] {
            return value
        }
        if let value = value as? NSArray {
            return value.map { $0 }
        }
        return nil
    }

    func stringValue(_ value: Any?) -> String? {
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

    func intValue(_ value: Any?) -> Int? {
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

    func uint64Value(_ value: Any?) -> UInt64? {
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

    func uint64ValueAllowingZero(_ value: Any?) -> UInt64? {
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

    func boolValue(_ value: Any?) -> Bool? {
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
