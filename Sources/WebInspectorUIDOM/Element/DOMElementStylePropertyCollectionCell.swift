#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementStylePropertyCollectionCell: UICollectionViewListCell {
    private static let modifiedBackgroundColor = UIColor.systemGreen.withProminence(.quaternary).withAlphaComponent(0.99)

    private let propertyView = DOMElementStylePropertyView()
    private var property: CSSStyleProperty?
    private var toggleAction: DOMElementStylePropertyView.ToggleAction?
    private var propertyObservation: PortableObservationTracking.Token?

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
        clear()
    }

    override package func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        renderBackground(
            isModifiedByInspector: property?.isModifiedByInspector == true,
            state: state
        )
    }

    /// The cell keeps its property identity and observes local presentation
    /// state without asking the collection view to reconfigure the row.
    package func bind(
        property: CSSStyleProperty,
        onToggle: DOMElementStylePropertyView.ToggleAction?
    ) {
        self.property = property
        toggleAction = onToggle
        propertyView.bind(property: property, onToggle: onToggle)
        propertyObservation?.cancel()
        propertyObservation = withPortableContinuousObservation { [weak self, weak property] _ in
            guard let self,
                  let property,
                  self.property === property else {
                return
            }
            self.renderBackground(
                isModifiedByInspector: property.isModifiedByInspector,
                state: self.configurationState
            )
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
