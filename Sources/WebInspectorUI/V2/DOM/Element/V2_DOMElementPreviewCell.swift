#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine

final class V2_DOMElementPreviewCell: V2_DOMElementBaseCell {
    private weak var node: DOMNodeModel?

    func bind(node: DOMNodeModel?) {
        resetObservationHandles()
        self.node = node
        render()

        guard let node else {
            return
        }

        store(
            node.observe(
                [\.preview, \.nodeType, \.nodeName, \.localName, \.nodeValue, \.attributes]
            ) { [weak self] in
                self?.render()
            }
        )
    }

    private func render() {
        guard let node else {
            contentConfiguration = nil
            accessories = []
            return
        }

        var configuration = UIListContentConfiguration.cell()
        configuration.text = node.preview.isEmpty ? Self.defaultPreview(for: node) : node.preview
        configuration.textProperties.numberOfLines = 0
        configuration.textProperties.font = Self.monospacedFootnoteFont
        configuration.textProperties.color = .label
        accessories = []
        contentConfiguration = configuration
    }
}

extension V2_DOMElementPreviewCell {
    private static func defaultPreview(for node: DOMNodeModel) -> String {
        switch node.nodeType {
        case 3:
            return node.nodeValue
        case 8:
            return "<!-- \(node.nodeValue) -->"
        default:
            let name = node.localName.isEmpty ? node.nodeName : node.localName
            let attributes = node.attributes.map { attribute in
                "\(attribute.name)=\"\(attribute.value)\""
            }.joined(separator: " ")
            let suffix = attributes.isEmpty ? "" : " \(attributes)"
            return "<\(name)\(suffix)>"
        }
    }
}

#endif
