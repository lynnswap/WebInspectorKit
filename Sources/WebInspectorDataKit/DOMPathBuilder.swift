import Foundation

private extension UnicodeScalar {
    var isCSSDigit: Bool {
        value >= 0x30 && value <= 0x39
    }

    var isCSSLetter: Bool {
        (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
    }

    var isCSSControlCharacter: Bool {
        (value >= 0x01 && value <= 0x1F) || value == 0x7F
    }

    var isCSSIdentifierCharacter: Bool {
        value >= 0x80 || isCSSLetter || isCSSDigit || value == 0x2D || value == 0x5F
    }
}

private struct DOMPathNode {
    let id: DOMNode.ID
    let nodeName: String
    let localName: String
    let kind: DOMNode.Kind
    let attributeList: [DOMNode.Attribute]
}

private struct DOMPathSnapshot {
    let nodesByID: [DOMNode.ID: DOMPathNode]
    let parentByNodeID: [DOMNode.ID: DOMNode.ID]
    let childrenByNodeID: [DOMNode.ID: [DOMNode.ID]]

    init(_ snapshot: DOMTreeSnapshot) {
        nodesByID = snapshot.nodesByID.mapValues {
            DOMPathNode(
                id: $0.id,
                nodeName: $0.nodeName,
                localName: $0.localName,
                kind: $0.kind,
                attributeList: $0.attributeList
            )
        }
        parentByNodeID = snapshot.parentByNodeID
        childrenByNodeID = snapshot.nodesByID.mapValues { node in
            snapshot.children(of: node.id)
        }
    }

    init(_ snapshot: WebInspectorDOMTreeSnapshot) {
        nodesByID = snapshot.rowsByID.mapValues {
            DOMPathNode(
                id: $0.id,
                nodeName: $0.nodeName,
                localName: $0.localName,
                kind: DOMNode.Kind(rawValue: $0.nodeType),
                attributeList: $0.attributeList
            )
        }
        parentByNodeID = snapshot.rowsByID.reduce(into: [:]) { result, element in
            if let parentID = element.value.parentID {
                result[element.key] = parentID
            }
        }
        childrenByNodeID = snapshot.rowsByID.mapValues { row in
            guard case let .loaded(ids) = row.children else {
                return []
            }
            return ids
        }
    }

    func node(for id: DOMNode.ID) -> DOMPathNode? {
        nodesByID[id]
    }

    func parent(of id: DOMNode.ID) -> DOMNode.ID? {
        parentByNodeID[id]
    }

    func children(of id: DOMNode.ID) -> [DOMNode.ID] {
        childrenByNodeID[id] ?? []
    }
}

public extension DOMTreeSnapshot {
    /// Returns a CSS selector path for the node, or an empty string when one cannot be built.
    func selectorPath(for id: DOMNode.ID) -> String {
        let pathSnapshot = DOMPathSnapshot(self)
        guard let node = pathSnapshot.node(for: id) else {
            return ""
        }
        return DOMPathBuilder(snapshot: pathSnapshot).selectorPath(for: node)
    }

    /// Returns an XPath expression for the node, or an empty string when one cannot be built.
    func xPath(for id: DOMNode.ID) -> String {
        let pathSnapshot = DOMPathSnapshot(self)
        guard let node = pathSnapshot.node(for: id) else {
            return ""
        }
        return DOMPathBuilder(snapshot: pathSnapshot).xPath(for: node)
    }
}

package extension WebInspectorDOMTreeSnapshot {
    func selectorPath(for id: DOMNode.ID) -> String {
        let pathSnapshot = DOMPathSnapshot(self)
        guard let node = pathSnapshot.node(for: id) else {
            return ""
        }
        return DOMPathBuilder(snapshot: pathSnapshot).selectorPath(for: node)
    }

    func xPath(for id: DOMNode.ID) -> String {
        let pathSnapshot = DOMPathSnapshot(self)
        guard let node = pathSnapshot.node(for: id) else {
            return ""
        }
        return DOMPathBuilder(snapshot: pathSnapshot).xPath(for: node)
    }
}

private struct DOMPathBuilder {
    let snapshot: DOMPathSnapshot

    func selectorPath(for node: DOMPathNode) -> String {
        guard nodeIsElementLike(node) else {
            return ""
        }

        var components: [String] = []
        var current: DOMPathNode? = node
        while let candidate = current {
            guard let component = selectorPathComponent(for: candidate) else {
                break
            }
            components.append(component.value)
            if component.done {
                break
            }
            current = selectorTraversalParent(for: candidate)
        }

        return components.reversed().joined(separator: " > ")
    }

    func xPath(for node: DOMPathNode) -> String {
        if node.kind == .document {
            return "/"
        }

        var components: [String] = []
        var current: DOMPathNode? = node
        while let candidate = current {
            if candidate.kind == .document {
                current = parent(of: candidate)
                continue
            }
            guard let component = xPathComponent(for: candidate) else {
                break
            }
            components.append(component)
            current = parent(of: candidate)
        }

        guard !components.isEmpty else {
            return ""
        }
        return "/" + components.reversed().joined(separator: "/")
    }

    private func parent(of node: DOMPathNode) -> DOMPathNode? {
        guard let parentID = snapshot.parent(of: node.id) else {
            return nil
        }
        return snapshot.node(for: parentID)
    }

    private func selectorTraversalParent(for node: DOMPathNode) -> DOMPathNode? {
        guard let parent = parent(of: node) else {
            return nil
        }
        if parent.kind == .document {
            return self.parent(of: parent)
        }
        return parent
    }

    private func selectorPathComponent(for node: DOMPathNode) -> (value: String, done: Bool)? {
        guard nodeIsElementLike(node) else {
            return nil
        }

        let nodeName = selectorNodeName(for: node)
        guard !nodeName.isEmpty else {
            return nil
        }

        let parent = selectorTraversalParent(for: node)
        if parent == nil || (["html", "body", "head"].contains(nodeName) && !nodeIsInsideEmbeddedDocument(node)) {
            return (nodeName, true)
        }

        if let idValue = attributeValue(named: "id", on: node),
            !idValue.isEmpty
        {
            return ("#\(escapedCSSIdentifier(idValue))", !nodeIsInsideEmbeddedDocument(node))
        }

        let siblings = selectorSiblingElements(for: node)
        var uniqueClasses = Set(classNames(for: node))
        var hasUniqueTagName = true
        var nthChildIndex = 0
        var elementIndex = 0

        for sibling in siblings {
            elementIndex += 1
            if sibling.id == node.id {
                nthChildIndex = elementIndex
                continue
            }
            if selectorNodeName(for: sibling) == nodeName {
                hasUniqueTagName = false
            }
            for className in classNames(for: sibling) {
                uniqueClasses.remove(className)
            }
        }

        var selector = nodeName
        if nodeName == "input",
            let typeValue = attributeValue(named: "type", on: node),
            !typeValue.isEmpty,
            uniqueClasses.isEmpty
        {
            selector += "[type=\"\(escapedCSSAttributeValue(typeValue))\"]"
        }

        if !hasUniqueTagName {
            if !uniqueClasses.isEmpty {
                selector += "." + uniqueClasses.sorted().map(escapedCSSIdentifier).joined(separator: ".")
            } else if nthChildIndex > 0 {
                selector += ":nth-child(\(nthChildIndex))"
            }
        }

        return (selector, false)
    }

    private func xPathComponent(for node: DOMPathNode) -> String? {
        func elementComponent() -> String? {
            let nodeName = selectorNodeName(for: node)
            guard !nodeName.isEmpty else {
                return nil
            }
            let index = xPathIndex(for: node)
            return index > 0 ? "\(nodeName)[\(index)]" : nodeName
        }

        switch node.kind {
        case .element:
            return elementComponent()
        case .attribute:
            return "@\(node.nodeName)"
        case .text, .cdataSection:
            let index = xPathIndex(for: node)
            return index > 0 ? "text()[\(index)]" : "text()"
        case .comment:
            let index = xPathIndex(for: node)
            return index > 0 ? "comment()[\(index)]" : "comment()"
        case .processingInstruction:
            let index = xPathIndex(for: node)
            return index > 0 ? "processing-instruction()[\(index)]" : "processing-instruction()"
        default:
            return nil
        }
    }

    private func xPathIndex(for node: DOMPathNode) -> Int {
        guard let parent = parent(of: node) else {
            return 0
        }

        let siblings = snapshot.children(of: parent.id).compactMap { snapshot.node(for: $0) }
        guard siblings.count > 1 else {
            return 0
        }

        var foundIndex = -1
        var counter = 1
        var unique = true

        for sibling in siblings where xPathNodesAreSimilar(node, sibling) {
            if sibling.id == node.id {
                foundIndex = counter
                if !unique {
                    return foundIndex
                }
            } else {
                unique = false
                if foundIndex != -1 {
                    return foundIndex
                }
            }
            counter += 1
        }

        if unique {
            return 0
        }
        return foundIndex > 0 ? foundIndex : 0
    }

    private func xPathNodesAreSimilar(_ lhs: DOMPathNode, _ rhs: DOMPathNode) -> Bool {
        if lhs.id == rhs.id {
            return true
        }
        if nodeIsElementLike(lhs), nodeIsElementLike(rhs) {
            return selectorNodeName(for: lhs) == selectorNodeName(for: rhs)
        }
        if lhs.kind == .cdataSection {
            return rhs.kind == .text
        }
        if rhs.kind == .cdataSection {
            return lhs.kind == .text
        }
        return lhs.kind == rhs.kind
    }

    private func selectorSiblingElements(for node: DOMPathNode) -> [DOMPathNode] {
        guard let parent = parent(of: node) else {
            return [node]
        }
        return snapshot.children(of: parent.id)
            .compactMap { snapshot.node(for: $0) }
            .filter(nodeIsElementLike)
    }

    private func selectorNodeName(for node: DOMPathNode) -> String {
        let rawName = node.localName.isEmpty ? node.nodeName : node.localName
        return rawName.lowercased()
    }

    private func nodeIsElementLike(_ node: DOMPathNode) -> Bool {
        guard node.kind == .element else {
            return false
        }
        let nodeName = selectorNodeName(for: node)
        return !nodeName.isEmpty && !nodeName.hasPrefix("#")
    }

    private func classNames(for node: DOMPathNode) -> [String] {
        guard let classValue = attributeValue(named: "class", on: node) else {
            return []
        }
        return
            classValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func attributeValue(named name: String, on node: DOMPathNode) -> String? {
        node.attributeList.first(where: { $0.name == name })?.value
    }

    private func nodeIsInsideEmbeddedDocument(_ node: DOMPathNode) -> Bool {
        var current = parent(of: node)
        while let currentNode = current {
            if currentNode.kind == .document, parent(of: currentNode) != nil {
                return true
            }
            current = parent(of: currentNode)
        }
        return false
    }

    private func escapedCSSIdentifier(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var escaped = ""
        for (index, scalar) in scalars.enumerated() {
            let isFirstScalar = index == 0
            let followsLeadingHyphen = index == 1 && scalars.first?.value == 0x2D
            if scalar.value == 0 {
                escaped.append("\u{FFFD}")
            } else if scalar.isCSSControlCharacter
                || (isFirstScalar && scalar.isCSSDigit)
                || (followsLeadingHyphen && scalar.isCSSDigit)
            {
                escaped.append("\\")
                escaped.append(String(scalar.value, radix: 16, uppercase: true))
                escaped.append(" ")
            } else if isFirstScalar && scalar.value == 0x2D && scalars.count == 1 {
                escaped.append(#"\-"#)
            } else if scalar.isCSSIdentifierCharacter {
                escaped.unicodeScalars.append(scalar)
            } else {
                escaped.append("\\")
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private func escapedCSSAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
