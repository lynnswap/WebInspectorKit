import Foundation
import Observation

struct DOMSelectionSnapshot {
    let nodeId: Int?
    let preview: String
    let attributes: [DOMAttribute]
    let path: [String]
    let selectorPath: String

    init?(dictionary: [String: Any]) {
        let nodeId = dictionary["id"] as? Int ?? dictionary["nodeId"] as? Int
        let preview = dictionary["preview"] as? String ?? ""
        let attributesPayload = dictionary["attributes"] as? [[String: Any]] ?? []
        let attributes = attributesPayload.compactMap { entry -> DOMAttribute? in
            guard let name = entry["name"] as? String else { return nil }
            let value = entry["value"] as? String ?? ""
            return DOMAttribute(nodeId: nodeId, name: name, value: value)
        }
        let path = dictionary["path"] as? [String] ?? []
        let selectorPath = dictionary["selectorPath"] as? String ?? ""

        if preview.isEmpty && attributes.isEmpty && path.isEmpty && selectorPath.isEmpty && nodeId == nil {
            return nil
        }

        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
    }
}

public struct DOMAttribute: Hashable, Identifiable, Sendable {
    public var id: String {
        if let nodeId {
            return "\(nodeId)#\(name)"
        }
        return "nil#\(name)"
    }
    
    public var nodeId: Int?
    public var name: String
    public var value: String

    public init(nodeId: Int? = nil, name: String, value: String) {
        self.nodeId = nodeId
        self.name = name
        self.value = value
    }
}

@MainActor
@Observable public final class DOMSelection {
    public var nodeId: Int?
    public var preview: String
    public var attributes: [DOMAttribute]
    public var path: [String]
    public var selectorPath: String

    public init(
        nodeId: Int? = nil,
        preview: String = "",
        attributes: [DOMAttribute] = [],
        path: [String] = [],
        selectorPath: String = ""
    ) {
        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
    }

    package func applySnapshot(from dictionary: [String: Any]) {
        let snapshot = DOMSelectionSnapshot(dictionary: dictionary)
        applySnapshot(snapshot)
    }

    private func applySnapshot(_ snapshot: DOMSelectionSnapshot?) {
        guard let snapshot else {
            clear()
            return
        }
        nodeId = snapshot.nodeId
        preview = snapshot.preview
        attributes = snapshot.attributes
        path = snapshot.path
        selectorPath = snapshot.selectorPath
    }

    package func clear() {
        nodeId = nil
        preview = ""
        attributes = []
        path = []
        selectorPath = ""
    }

    package func updateAttributeValue(nodeId: Int?, name: String, value: String) {
        guard nodeId == self.nodeId, let index = attributes.firstIndex(where: { $0.name == name }) else {
            return
        }
        attributes[index].value = value
    }

    package func removeAttribute(nodeId: Int?, name: String) {
        guard nodeId == self.nodeId else { return }
        attributes.removeAll { $0.name == name }
    }
}
