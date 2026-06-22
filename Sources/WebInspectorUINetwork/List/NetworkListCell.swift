#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorCore
import UIKit

@MainActor
package final class NetworkListCell: UICollectionViewListCell {
    private struct AccessorySignature: Equatable {
        var indentLevel: Int
        var isExpandable: Bool
    }

    private static let indentationStepWidth: CGFloat = 24

    private let expansionButton = UIButton(type: .system)
    private let indentationView = UIView(frame: .zero)
    private let statusIndicatorView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    private let fileTypeLabel = UILabel()
    private var boundEntryID: NetworkDisplayEntry.ID?
    private var boundPresentation: NetworkDisplayEntryPresentation?
    private var expansionAction: (@MainActor (NetworkDisplayEntry.ID) -> Void)?
    private var isRenderingActive = true
    private var accessorySignature: AccessorySignature?
#if DEBUG
    private var renderedIndentationWidthForTestingStorage: CGFloat = 0
    private var hasExpansionButtonAccessoryForTestingStorage = false
#endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        unbind()
    }

    package func bind(
        entryID: NetworkDisplayEntry.ID,
        presentation: NetworkDisplayEntryPresentation,
        renderingActive: Bool,
        expansionAction: @escaping @MainActor (NetworkDisplayEntry.ID) -> Void
    ) {
        boundEntryID = entryID
        boundPresentation = presentation
        self.expansionAction = expansionAction
        setRenderingActive(renderingActive)
    }

    package func setRenderingActive(_ isActive: Bool) {
        isRenderingActive = isActive
        guard isActive, let boundPresentation else {
            return
        }
        render(presentation: boundPresentation)
    }

    package func unbind() {
        boundEntryID = nil
        boundPresentation = nil
        expansionAction = nil
        render(
            presentation: NetworkDisplayEntryPresentation(
                displayName: "",
                statusSeverity: .neutral,
                fileTypeLabel: "",
                style: .resource
            )
        )
    }

    private func configureStaticViews() {
        expansionButton.accessibilityIdentifier = "WebInspector.Network.List.ExpansionButton"
        expansionButton.tintColor = .secondaryLabel
        expansionButton.addTarget(self, action: #selector(expansionButtonTapped(_:)), for: .touchUpInside)

        indentationView.isUserInteractionEnabled = false
        indentationView.backgroundColor = .clear

        statusIndicatorView.accessibilityIdentifier = "WebInspector.Network.List.StatusIndicator"
        statusIndicatorView.layer.cornerRadius = 4

        fileTypeLabel.accessibilityIdentifier = "WebInspector.Network.List.FileTypeLabel"
        fileTypeLabel.textColor = .secondaryLabel
        fileTypeLabel.font = .preferredFont(forTextStyle: .footnote)
        fileTypeLabel.adjustsFontForContentSizeCategory = true

        contentConfiguration = Self.makeContentConfiguration()
    }

    @objc private func expansionButtonTapped(_ sender: UIButton) {
        guard let boundEntryID else {
            return
        }
        expansionAction?(boundEntryID)
    }

    private func render(presentation: NetworkDisplayEntryPresentation) {
        renderText(presentation)
        renderAccessories(presentation)
    }

    private func renderText(_ presentation: NetworkDisplayEntryPresentation) {
        var content = (contentConfiguration as? UIListContentConfiguration) ?? Self.makeContentConfiguration()
        let displayName = presentation.displayName
        let secondaryText = presentation.secondaryText
        guard content.text != displayName || content.secondaryText != secondaryText else {
            return
        }
        content.text = displayName
        content.secondaryText = secondaryText
        contentConfiguration = content
    }

    private func renderAccessories(_ presentation: NetworkDisplayEntryPresentation) {
        let color = presentation.statusSeverity.color
        if statusIndicatorView.backgroundColor?.isEqual(color) != true {
            statusIndicatorView.backgroundColor = color
        }
        if self.fileTypeLabel.text != presentation.fileTypeLabel {
            self.fileTypeLabel.text = presentation.fileTypeLabel
        }
        let imageName = presentation.isExpanded ? "chevron.down" : "chevron.right"
        let currentImage = expansionButton.image(for: .normal)
        if currentImage == nil || expansionButton.accessibilityLabel != imageName {
            expansionButton.setImage(UIImage(systemName: imageName), for: .normal)
            expansionButton.accessibilityLabel = imageName
        }

        let signature = AccessorySignature(
            indentLevel: presentation.indentLevel,
            isExpandable: presentation.isExpandable
        )
        guard accessorySignature != signature else {
            return
        }
        accessorySignature = signature
        accessories = makeAccessories(for: presentation)
    }

    private func makeAccessories(for presentation: NetworkDisplayEntryPresentation) -> [UICellAccessory] {
        var accessories: [UICellAccessory] = []

        let indentationWidth = CGFloat(max(0, presentation.indentLevel)) * Self.indentationStepWidth
        if indentationWidth > 0 {
            accessories.append(
                .customView(
                    configuration: .init(
                        customView: indentationView,
                        placement: .leading(),
                        reservedLayoutWidth: .custom(indentationWidth),
                        maintainsFixedSize: true
                    )
                )
            )
        }

        if presentation.isExpandable {
            accessories.append(
                .customView(
                    configuration: .init(
                        customView: expansionButton,
                        placement: .leading(),
                        reservedLayoutWidth: .custom(Self.indentationStepWidth),
                        maintainsFixedSize: true
                    )
                )
            )
        }

        accessories.append(
            .customView(
                configuration: .init(
                    customView: statusIndicatorView,
                    placement: .leading(),
                    reservedLayoutWidth: .custom(8),
                    maintainsFixedSize: true
                )
            )
        )
        accessories.append(
            .customView(
                configuration: .init(
                    customView: fileTypeLabel,
                    placement: .trailing(),
                    reservedLayoutWidth: .actual,
                    maintainsFixedSize: false
                )
            )
        )
        accessories.append(.disclosureIndicator())

#if DEBUG
        renderedIndentationWidthForTestingStorage = indentationWidth
        hasExpansionButtonAccessoryForTestingStorage = presentation.isExpandable
#endif
        return accessories
    }

    private static func makeContentConfiguration() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.secondaryText = nil
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        return content
    }
}

#if DEBUG
extension NetworkListCell {
    package var displayNameForTesting: String? {
        (contentConfiguration as? UIListContentConfiguration)?.text
    }

    package var fileTypeLabelForTesting: String? {
        fileTypeLabel.text
    }

    package var statusIndicatorColorForTesting: UIColor? {
        statusIndicatorView.backgroundColor
    }

    package var hasActiveRequestObservationForTesting: Bool {
        false
    }

    package var renderedIndentationWidthForTesting: CGFloat {
        renderedIndentationWidthForTestingStorage
    }

    package var hasExpansionButtonAccessoryForTesting: Bool {
        hasExpansionButtonAccessoryForTestingStorage
    }
}
#endif
#endif
