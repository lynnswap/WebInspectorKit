#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorProxyKit
import UIKit

@MainActor
package final class DOMElementStylePropertyCollectionCell: UICollectionViewListCell {
    private static let modifiedBackgroundColor = UIColor.systemGreen.withProminence(.quaternary).withAlphaComponent(0.99)

    private let propertyView = DOMElementStylePropertyView()
    private var property: CSS.Property?
    private var toggleAction: DOMElementStylePropertyView.ToggleAction?

    override package init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }

    override package func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        renderBackground(
            isModifiedByInspector: property?.isModifiedByInspector == true,
            state: state
        )
    }

    /// Properties are value types: the cell renders the configured value
    /// once and is re-rendered through the coordinator's reconfigure path
    /// when the row's content changes.
    package func bind(
        property: CSS.Property,
        onToggle: DOMElementStylePropertyView.ToggleAction?
    ) {
        self.property = property
        toggleAction = onToggle
        render(property)
    }

    package func clear() {
        property = nil
        toggleAction = nil
        propertyView.clear()
        renderBackground(
            isModifiedByInspector: false,
            state: configurationState
        )
    }

    private func configureStaticViews() {
        contentView.preservesSuperviewLayoutMargins = true
        propertyView.translatesAutoresizingMaskIntoConstraints = false
        propertyView.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)

        contentView.addSubview(propertyView)
        NSLayoutConstraint.activate([
            propertyView.topAnchor.constraint(equalTo: contentView.topAnchor),
            propertyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            propertyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            propertyView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func render(_ property: CSS.Property) {
        propertyView.render(property: property, onToggle: toggleAction)
        renderBackground(
            isModifiedByInspector: property.isModifiedByInspector,
            state: configurationState
        )
    }

    private func renderBackground(
        isModifiedByInspector: Bool,
        state: UICellConfigurationState
    ) {
        var background = defaultBackgroundConfiguration().updated(for: state)
        if isModifiedByInspector {
            background.backgroundColor = Self.modifiedBackgroundColor
        }
        backgroundConfiguration = background
    }
}

#if DEBUG
extension DOMElementStylePropertyCollectionCell {
    package var propertyViewForTesting: DOMElementStylePropertyView {
        propertyView
    }

    package var usesModifiedBackgroundForTesting: Bool {
        backgroundConfiguration?.backgroundColor == Self.modifiedBackgroundColor
    }
}
#endif
#endif
