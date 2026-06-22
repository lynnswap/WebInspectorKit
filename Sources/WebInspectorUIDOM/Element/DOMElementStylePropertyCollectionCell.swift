#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementStylePropertyCollectionCell: UICollectionViewListCell {
    private static let modifiedBackgroundColor = UIColor.systemGreen.withProminence(.quaternary).withAlphaComponent(0.99)

    private var propertyObservation: PortableObservationTracking.Token?
    private let propertyView = DOMElementStylePropertyView()
    private weak var property: CSSProperty?
    private var toggleAction: DOMElementStylePropertyView.ToggleAction?

    override package init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        propertyObservation?.cancel()
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        unbind()
    }

    override package func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        renderBackground(
            isModifiedByInspector: property?.isModifiedByInspector == true,
            state: state
        )
    }

    package func bind(
        property: CSSProperty,
        onToggle: DOMElementStylePropertyView.ToggleAction?
    ) {
        self.property = property
        toggleAction = onToggle

        propertyObservation?.cancel()
        propertyObservation = withPortableContinuousObservation { [weak self, weak property] _ in
            guard let self else {
                return
            }
            guard let property else {
                self.clear()
                return
            }
            self.render(property)
        }
    }

    package func clear() {
        propertyObservation?.cancel()
        propertyObservation = nil
        property = nil
        toggleAction = nil
        propertyView.clear()
        renderBackground(
            isModifiedByInspector: false,
            state: configurationState
        )
    }

    private func unbind() {
        propertyObservation?.cancel()
        propertyObservation = nil
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

    private func render(_ property: CSSProperty) {
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
