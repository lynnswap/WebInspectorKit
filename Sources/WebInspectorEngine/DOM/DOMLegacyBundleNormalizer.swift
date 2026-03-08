import Foundation

struct DOMLegacyProtocolEvent {
    let method: String
    let paramsData: Data
}

enum DOMLegacyBundleDelta {
    case snapshot(DOMGraphSnapshot, resetDocument: Bool)
    case mutations(DOMGraphMutationBundle)
}

struct DOMLegacyBundleParseResult {
    let delta: DOMLegacyBundleDelta
    let protocolEvents: [DOMLegacyProtocolEvent]
}

@MainActor
final class DOMLegacyBundleNormalizer {
    private var nextFallbackNodeID = -1

    func parseBundlePayload(_ payload: Any) -> DOMLegacyBundleParseResult? {
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
                  let snapshot = normalizeSnapshotPayload(snapshotPayload) else {
                return nil
            }
            let protocolEvents: [DOMLegacyProtocolEvent]
            if shouldResetDocument {
                protocolEvents = []
            } else {
                protocolEvents = [makeProtocolEvent(method: "DOM.documentUpdated", params: [:])]
            }
            return DOMLegacyBundleParseResult(
                delta: .snapshot(snapshot, resetDocument: shouldResetDocument),
                protocolEvents: protocolEvents
            )

        case "mutation":
            guard let events = arrayValue(object["events"]) else {
                return nil
            }
            let bundle = DOMGraphMutationBundle(events: normalizeMutationEvents(events))
            return DOMLegacyBundleParseResult(
                delta: .mutations(bundle),
                protocolEvents: normalizeProtocolEvents(events)
            )

        default:
            return nil
        }
    }

    func normalizeSnapshotPayload(_ payload: Any) -> DOMGraphSnapshot? {
        guard let snapshotObject = resolveSnapshotPayload(payload) else {
            return nil
        }

        guard let rootPayload = snapshotObject["root"],
              let root = normalizeNodeDescriptor(rootPayload) else {
            return nil
        }

        let selectedNodeID = resolveSelectedNodeID(snapshotObject, root: root)
        return DOMGraphSnapshot(root: root, selectedNodeID: selectedNodeID)
    }

    func normalizeSubtreePayload(_ payload: Any) -> DOMGraphNodeDescriptor? {
        let normalizedPayload = resolveNodePayload(payload) ?? payload
        return normalizeNodeDescriptor(normalizedPayload)
    }

    func resetForDocumentUpdate() {
        nextFallbackNodeID = -1
    }
}

private extension DOMLegacyBundleNormalizer {
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

        let resolvedRoot = mergeSerializedRootWithFallback(
            serialized: dictionaryValue(rootFromNode),
            fallback: dictionaryValue(rootFromFallback)
        ) ?? dictionaryValue(rootFromNode) ?? dictionaryValue(rootFromFallback)

        guard let resolvedRoot else {
            return fallbackSnapshot
        }

        var resolved: [String: Any] = ["root": resolvedRoot]
        if let selectedNodeID = intValue(envelope["selectedNodeId"]) ?? intValue(fallbackSnapshot?["selectedNodeId"]) {
            resolved["selectedNodeId"] = selectedNodeID
        }
        if let selectedNodePath = normalizeNodePath(envelope["selectedNodePath"]) ?? normalizeNodePath(fallbackSnapshot?["selectedNodePath"]) {
            resolved["selectedNodePath"] = selectedNodePath
        }
        return resolved
    }

    func mergeSerializedRootWithFallback(
        serialized: [String: Any]?,
        fallback: [String: Any]?
    ) -> [String: Any]? {
        if serialized == nil, fallback == nil {
            return nil
        }
        guard let serialized else {
            return fallback
        }
        guard let fallback else {
            return serialized
        }

        var merged = fallback
        for (key, value) in serialized {
            merged[key] = value
        }

        let serializedChildren = arrayValue(serialized["children"])?.compactMap(dictionaryValue) ?? []
        let fallbackChildren = arrayValue(fallback["children"])?.compactMap(dictionaryValue) ?? []
        let childCount = max(serializedChildren.count, fallbackChildren.count)

        if childCount > 0 {
            var children: [[String: Any]] = []
            children.reserveCapacity(childCount)
            for index in 0..<childCount {
                let serializedChild = index < serializedChildren.count ? serializedChildren[index] : nil
                let fallbackChild = index < fallbackChildren.count ? fallbackChildren[index] : nil
                if let mergedChild = mergeSerializedRootWithFallback(
                    serialized: serializedChild,
                    fallback: fallbackChild
                ) {
                    children.append(mergedChild)
                }
            }
            merged["children"] = children
        } else if let existingChildren = merged["children"] as? [Any], existingChildren.isEmpty {
            merged.removeValue(forKey: "children")
        }

        return merged
    }

    func resolveSelectedNodeID(_ snapshotObject: [String: Any], root: DOMGraphNodeDescriptor) -> Int? {
        if let selectedNodeID = intValue(snapshotObject["selectedNodeId"]) {
            return selectedNodeID
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
        return current.nodeID
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

    func normalizeNodeDescriptor(_ payload: Any) -> DOMGraphNodeDescriptor? {
        guard let object = dictionaryValue(payload) else {
            return nil
        }

        if isSerializedNodeEnvelope(object),
           let resolved = resolveSerializedNodeEnvelope(object),
           let root = resolved["root"] {
            return normalizeNodeDescriptor(root)
        }

        let nodeID = intValue(object["nodeId"]) ?? intValue(object["id"]) ?? allocateFallbackNodeID()
        let nodeType = intValue(object["nodeType"]) ?? 0
        let nodeName = stringValue(object["nodeName"]) ?? ""
        let localName = stringValue(object["localName"]) ?? ""
        let nodeValue = stringValue(object["nodeValue"]) ?? ""
        let attributes = normalizeNodeAttributes(object["attributes"], nodeID: nodeID)
        let childPayloads = arrayValue(object["children"]) ?? []
        let layoutFlags = normalizeLayoutFlags(object["layoutFlags"])
        let isRendered = boolValue(object["isRendered"]) ?? true

        var children: [DOMGraphNodeDescriptor] = []
        children.reserveCapacity(childPayloads.count)
        for childPayload in childPayloads {
            if let child = normalizeNodeDescriptor(childPayload) {
                children.append(child)
            }
        }

        let childCount = intValue(object["childNodeCount"])
            ?? intValue(object["childCount"])
            ?? children.count

        return DOMGraphNodeDescriptor(
            nodeID: nodeID,
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

        for entry in events {
            guard let object = dictionaryValue(entry),
                  let rawMethod = stringValue(object["method"]) else {
                continue
            }

            let method = rawMethod.hasPrefix("DOM.") ? String(rawMethod.dropFirst(4)) : rawMethod
            let params = dictionaryValue(object["params"]) ?? [:]

            switch method {
            case "childNodeInserted":
                guard let parentNodeID = intValue(params["parentNodeId"]) ?? intValue(params["parentId"]),
                      let nodePayload = params["node"],
                      let node = normalizeNodeDescriptor(nodePayload) else {
                    continue
                }
                let previousNodeID = intValueAllowingZero(params["previousNodeId"]) ?? intValueAllowingZero(params["previousId"])
                normalized.append(
                    .childNodeInserted(
                        parentNodeID: parentNodeID,
                        previousNodeID: previousNodeID,
                        node: node
                    )
                )

            case "childNodeRemoved":
                guard let parentNodeID = intValue(params["parentNodeId"]) ?? intValue(params["parentId"]),
                      let nodeID = intValue(params["nodeId"]) else {
                    continue
                }
                normalized.append(.childNodeRemoved(parentNodeID: parentNodeID, nodeID: nodeID))

            case "attributeModified":
                guard let nodeID = intValue(params["nodeId"]),
                      let name = stringValue(params["name"]) else {
                    continue
                }
                normalized.append(
                    .attributeModified(
                        nodeID: nodeID,
                        name: name,
                        value: stringValue(params["value"]) ?? "",
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "attributeRemoved":
                guard let nodeID = intValue(params["nodeId"]),
                      let name = stringValue(params["name"]) else {
                    continue
                }
                normalized.append(
                    .attributeRemoved(
                        nodeID: nodeID,
                        name: name,
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "characterDataModified":
                guard let nodeID = intValue(params["nodeId"]) else {
                    continue
                }
                normalized.append(
                    .characterDataModified(
                        nodeID: nodeID,
                        value: stringValue(params["characterData"]) ?? "",
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "childNodeCountUpdated":
                guard let nodeID = intValue(params["nodeId"]),
                      let childCount = intValue(params["childNodeCount"]) ?? intValue(params["childCount"]) else {
                    continue
                }
                normalized.append(
                    .childNodeCountUpdated(
                        nodeID: nodeID,
                        childCount: childCount,
                        layoutFlags: normalizeLayoutFlags(params["layoutFlags"]),
                        isRendered: boolValue(params["isRendered"])
                    )
                )

            case "setChildNodes":
                guard let parentNodeID = intValue(params["parentNodeId"]) ?? intValue(params["parentId"]) else {
                    continue
                }
                let nodesPayload = arrayValue(params["nodes"]) ?? []
                let nodes = nodesPayload.compactMap(normalizeNodeDescriptor)
                normalized.append(.setChildNodes(parentNodeID: parentNodeID, nodes: nodes))

            case "documentUpdated":
                normalized.append(.documentUpdated)
                resetForDocumentUpdate()

            default:
                continue
            }
        }

        return normalized
    }

    func normalizeProtocolEvents(_ events: [Any]) -> [DOMLegacyProtocolEvent] {
        events.compactMap { entry in
            guard let object = dictionaryValue(entry),
                  let method = stringValue(object["method"]) else {
                return nil
            }

            let params = dictionaryValue(object["params"]) ?? [:]
            return makeProtocolEvent(method: method, params: params)
        }
    }

    func makeProtocolEvent(method: String, params: [String: Any]) -> DOMLegacyProtocolEvent {
        let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        return DOMLegacyProtocolEvent(method: method, paramsData: paramsData)
    }

    func normalizeNodeAttributes(_ payload: Any?, nodeID: Int) -> [DOMAttribute] {
        guard let values = arrayValue(payload) else {
            return []
        }

        if values.allSatisfy({ $0 is String }) {
            var attributes: [DOMAttribute] = []
            var index = 0
            while index + 1 < values.count {
                let name = stringValue(values[index]) ?? ""
                let value = stringValue(values[index + 1]) ?? ""
                attributes.append(DOMAttribute(nodeId: nodeID, name: name, value: value))
                index += 2
            }
            return attributes
        }

        return values.compactMap { entry in
            guard let object = dictionaryValue(entry),
                  let name = stringValue(object["name"]) else {
                return nil
            }
            let value = stringValue(object["value"]) ?? ""
            return DOMAttribute(nodeId: nodeID, name: name, value: value)
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

        guard intValue(object["nodeId"]) != nil || intValue(object["id"]) != nil else {
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

    func allocateFallbackNodeID() -> Int {
        let current = nextFallbackNodeID
        nextFallbackNodeID -= 1
        return current
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

    func intValueAllowingZero(_ value: Any?) -> Int? {
        intValue(value)
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
