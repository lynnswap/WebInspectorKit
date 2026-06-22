import WebInspectorCoreRuntime
import WebInspectorCoreSupport
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

@MainActor
struct DOMPathBuilder {
    private let nodeProvider: (DOMNode.ID) -> DOMNode?

    init(nodeProvider: @escaping (DOMNode.ID) -> DOMNode?) {
        self.nodeProvider = nodeProvider
    }

    func selectorPath(for node: DOMNode) -> String {
        guard nodeIsElementLike(node) else {
            return ""
        }

        var components: [String] = []
        var current: DOMNode? = node
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

    func xPath(for node: DOMNode) -> String {
        if node.nodeType == .document {
            return "/"
        }

        var components: [String] = []
        var current: DOMNode? = node
        while let candidate = current {
            if candidate.nodeType == .document {
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

    private func parent(of node: DOMNode) -> DOMNode? {
        guard let parentID = node.parentID else {
            return nil
        }
        return nodeProvider(parentID)
    }

    private func selectorTraversalParent(for node: DOMNode) -> DOMNode? {
        guard let parent = parent(of: node) else {
            return nil
        }
        if parent.nodeType == .document {
            return self.parent(of: parent)
        }
        return parent
    }

    private func selectorPathComponent(for node: DOMNode) -> (value: String, done: Bool)? {
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
           !idValue.isEmpty {
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
           uniqueClasses.isEmpty {
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

    private func xPathComponent(for node: DOMNode) -> String? {
        func elementComponent() -> String? {
            let nodeName = selectorNodeName(for: node)
            guard !nodeName.isEmpty else {
                return nil
            }
            let index = xPathIndex(for: node)
            return index > 0 ? "\(nodeName)[\(index)]" : nodeName
        }

        switch node.nodeType {
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

    private func xPathIndex(for node: DOMNode) -> Int {
        guard let parent = parent(of: node) else {
            return 0
        }

        let siblings = parent.regularChildren.loadedChildren.compactMap { nodeProvider($0) }
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

    private func xPathNodesAreSimilar(_ lhs: DOMNode, _ rhs: DOMNode) -> Bool {
        if lhs.id == rhs.id {
            return true
        }
        if nodeIsElementLike(lhs), nodeIsElementLike(rhs) {
            return selectorNodeName(for: lhs) == selectorNodeName(for: rhs)
        }
        if lhs.nodeType == .cdataSection {
            return rhs.nodeType == .text
        }
        if rhs.nodeType == .cdataSection {
            return lhs.nodeType == .text
        }
        return lhs.nodeType == rhs.nodeType
    }

    private func selectorSiblingElements(for node: DOMNode) -> [DOMNode] {
        guard let parent = parent(of: node) else {
            return [node]
        }
        return parent.regularChildren.loadedChildren.compactMap { nodeProvider($0) }.filter(nodeIsElementLike)
    }

    private func selectorNodeName(for node: DOMNode) -> String {
        let rawName = node.localName.isEmpty ? node.nodeName : node.localName
        return rawName.lowercased()
    }

    private func nodeIsElementLike(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element else {
            return false
        }
        let nodeName = selectorNodeName(for: node)
        return !nodeName.isEmpty && !nodeName.hasPrefix("#")
    }

    private func classNames(for node: DOMNode) -> [String] {
        guard let classValue = attributeValue(named: "class", on: node) else {
            return []
        }
        return classValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func attributeValue(named name: String, on node: DOMNode) -> String? {
        node.attributes.first(where: { $0.name == name })?.value
    }

    private func nodeIsInsideEmbeddedDocument(_ node: DOMNode) -> Bool {
        var current = parent(of: node)
        while let currentNode = current {
            if currentNode.nodeType == .document, parent(of: currentNode) != nil {
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
                || (followsLeadingHyphen && scalar.isCSSDigit) {
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
