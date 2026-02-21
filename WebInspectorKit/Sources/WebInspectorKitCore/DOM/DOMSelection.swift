import Foundation
import Observation

struct DOMSelectionSnapshot {
    let nodeId: Int?
    let preview: String
    let attributes: [DOMAttribute]
    let path: [String]
    let selectorPath: String
    let styleRevision: Int

    init?(dictionary: NSDictionary) {
        let nodeId = dictionary["id"] as? Int ?? dictionary["nodeId"] as? Int
        let preview = dictionary["preview"] as? String ?? ""
        let attributesPayload = dictionary["attributes"] as? [NSDictionary] ?? []
        let attributes = attributesPayload.compactMap { entry -> DOMAttribute? in
            guard let name = entry["name"] as? String else { return nil }
            let value = entry["value"] as? String ?? ""
            return DOMAttribute(nodeId: nodeId, name: name, value: value)
        }
        let path = dictionary["path"] as? [String] ?? []
        let selectorPath = dictionary["selectorPath"] as? String ?? ""
        let styleRevision: Int
        if let revision = dictionary["styleRevision"] as? Int {
            styleRevision = revision
        } else if let revision = dictionary["styleRevision"] as? NSNumber {
            styleRevision = revision.intValue
        } else {
            styleRevision = 0
        }

        if preview.isEmpty && attributes.isEmpty && path.isEmpty && selectorPath.isEmpty && nodeId == nil {
            return nil
        }

        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
        self.styleRevision = styleRevision
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
    public var styleRevision: Int
    public var matchedStyles: [DOMMatchedStyleRule]
    public var isLoadingMatchedStyles: Bool
    public var matchedStylesTruncated: Bool
    public var blockedStylesheetCount: Int

    public init(
        nodeId: Int? = nil,
        preview: String = "",
        attributes: [DOMAttribute] = [],
        path: [String] = [],
        selectorPath: String = "",
        styleRevision: Int = 0,
        matchedStyles: [DOMMatchedStyleRule] = [],
        isLoadingMatchedStyles: Bool = false,
        matchedStylesTruncated: Bool = false,
        blockedStylesheetCount: Int = 0
    ) {
        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
        self.selectorPath = selectorPath
        self.styleRevision = styleRevision
        self.matchedStyles = matchedStyles
        self.isLoadingMatchedStyles = isLoadingMatchedStyles
        self.matchedStylesTruncated = matchedStylesTruncated
        self.blockedStylesheetCount = blockedStylesheetCount
    }

    package func applySnapshot(from dictionary: NSDictionary) {
        let snapshot = DOMSelectionSnapshot(dictionary: dictionary)
        applySnapshot(snapshot)
    }

    private func applySnapshot(_ snapshot: DOMSelectionSnapshot?) {
        guard let snapshot else {
            clear()
            return
        }
        let previousNodeId = nodeId
        nodeId = snapshot.nodeId
        preview = snapshot.preview
        attributes = snapshot.attributes
        path = snapshot.path
        selectorPath = snapshot.selectorPath
        styleRevision = snapshot.styleRevision
        if previousNodeId != snapshot.nodeId {
            clearMatchedStyles()
        }
    }

    package func clear() {
        nodeId = nil
        preview = ""
        attributes = []
        path = []
        selectorPath = ""
        styleRevision = 0
        clearMatchedStyles()
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

    package func beginMatchedStylesLoading(for nodeId: Int) {
        guard self.nodeId == nodeId else {
            return
        }
        isLoadingMatchedStyles = true
        matchedStyles = []
        matchedStylesTruncated = false
        blockedStylesheetCount = 0
    }

    package func applyMatchedStyles(_ payload: DOMMatchedStylesPayload, for nodeId: Int) {
        guard self.nodeId == nodeId, payload.nodeId == nodeId else {
            return
        }
        matchedStyles = payload.rules
        matchedStylesTruncated = payload.truncated
        blockedStylesheetCount = payload.blockedStylesheetCount
        isLoadingMatchedStyles = false
    }

    package func clearMatchedStyles() {
        matchedStyles = []
        matchedStylesTruncated = false
        blockedStylesheetCount = 0
        isLoadingMatchedStyles = false
    }
}
