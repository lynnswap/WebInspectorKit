import Foundation
import Observation

struct WIDOMSelectionSnapshot {
    let nodeId: Int?
    let preview: String
    let attributes: [(name: String, value: String)]
    let path: [String]
    let selectorPath: String

    init?(dictionary: [String: Any]) {
        let nodeId = dictionary["id"] as? Int ?? dictionary["nodeId"] as? Int
        let preview = dictionary["preview"] as? String ?? ""
        let attributesPayload = dictionary["attributes"] as? [[String: Any]] ?? []
        let attributes = attributesPayload.compactMap { entry -> (name: String, value: String)? in
            guard let name = entry["name"] as? String else { return nil }
            let value = entry["value"] as? String ?? ""
            return (name: name, value: value)
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

public struct WIDOMAttribute: Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

@MainActor
@Observable public final class WIDOMSelection {
    public var nodeId: Int?
    public var preview: String
    public var attributes: [WIDOMAttribute]
    public var path: [String]
    public var selectorPath: String

    public init(
        nodeId: Int? = nil,
        preview: String = "",
        attributes: [WIDOMAttribute] = [],
        path: [String] = [],
        selectorPath: String = ""
    ) {
        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
    }

    func applySnapshot(from dictionary: [String: Any]) {
        let snapshot = WIDOMSelectionSnapshot(dictionary: dictionary)
        applySnapshot(snapshot)
    }

    func applySnapshot(_ snapshot: WIDOMSelectionSnapshot?) {
        guard let snapshot else {
            clear()
            return
        }
        nodeId = snapshot.nodeId
        preview = snapshot.preview
        attributes = snapshot.attributes.map { WIDOMAttribute(name: $0.name, value: $0.value) }
        path = snapshot.path
        selectorPath = snapshot.selectorPath
    }

    func clear() {
        nodeId = nil
        preview = ""
        attributes = []
        path = []
        selectorPath = ""
    }
}
