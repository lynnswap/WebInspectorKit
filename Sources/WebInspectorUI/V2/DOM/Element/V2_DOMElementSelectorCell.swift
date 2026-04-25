#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine

final class V2_DOMElementSelectorCell: V2_DOMElementBaseCell {
    private weak var node: DOMNodeModel?

    func bind(node: DOMNodeModel?) {
        resetObservationHandles()
        self.node = node
        render()

        guard let node else {
            return
        }

        store(
            node.observe(\.selectorPath) { [weak self] _ in
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
        configuration.text = node.selectorPath
        configuration.textProperties.numberOfLines = 0
        configuration.textProperties.font = Self.monospacedFootnoteFont
        configuration.textProperties.color = .label
        accessories = []
        contentConfiguration = configuration
    }
}
#endif
