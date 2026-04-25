#if canImport(UIKit)
import UIKit
import WebInspectorEngine

final class V2_DOMElementAttributeCell: V2_DOMElementBaseCell {
    func bind(_ attribute: DOMAttribute?) {
        guard let attribute else {
            contentConfiguration = nil
            accessories = []
            return
        }

        var configuration = UIListContentConfiguration.cell()
        configuration.text = attribute.name
        configuration.secondaryText = attribute.value
        configuration.textProperties.color = .secondaryLabel
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.font = Self.monospacedFootnoteFont
        configuration.secondaryTextProperties.color = .label
        accessories = []
        contentConfiguration = configuration
    }
}
#endif
