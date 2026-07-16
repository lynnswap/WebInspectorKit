#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class NetworkListCell: UICollectionViewListCell {
    package enum ListPosition: Equatable {
        case single
        case first
        case middle
        case last
    }

    private let statusIndicatorView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    private let fileTypeLabel = UILabel()
    private let separatorView = UIView()
    private var listPosition: ListPosition = .middle
    private var entryObservation: PortableObservationTracking.Token?
    private weak var observedEntry: NetworkListEntry?
    private var isRenderingActive = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        entryObservation?.cancel()
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        unbind()
    }

    override package func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        updateBackgroundShape()
    }

    override package func layoutSubviews() {
        super.layoutSubviews()
        updateBackgroundShape()
    }

    package func bind(entry: NetworkListEntry, renderingActive: Bool) {
        if observedEntry !== entry {
            cancelEntryObservation()
            observedEntry = entry
        }
        setRenderingActive(renderingActive)
    }

    package func setRenderingActive(_ isActive: Bool) {
        guard isRenderingActive != isActive else {
            if isActive {
                renderObservedEntry()
                startRequestObservationIfNeeded()
            }
            return
        }

        isRenderingActive = isActive
        if isActive {
            renderObservedEntry()
            startRequestObservationIfNeeded()
        } else {
            cancelEntryObservation()
        }
    }

    package func unbind() {
        cancelEntryObservation()
        observedEntry = nil
        render(displayName: "", statusSeverity: .neutral, fileTypeLabel: "")
    }

    package func setListPosition(_ position: ListPosition) {
        guard listPosition != position else {
            return
        }
        listPosition = position
        separatorView.isHidden = position == .single || position == .last
        var background = UIBackgroundConfiguration.listCell()
        background.cornerRadius = position == .middle ? 0 : 10
        backgroundConfiguration = background
        updateBackgroundShape()
    }

    private func updateBackgroundShape() {
        guard let backgroundView else {
            return
        }
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.layer.maskedCorners = switch listPosition {
        case .single:
            [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .first:
            [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .middle:
            []
        case .last:
            [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        backgroundView.layer.masksToBounds = listPosition != .middle
    }

    private func startRequestObservationIfNeeded() {
        guard entryObservation == nil,
              let observedEntry else {
            return
        }
        entryObservation = withPortableContinuousObservation { [weak self, weak observedEntry] _ in
            guard let self,
                  let observedEntry,
                  self.isRenderingActive,
                  self.observedEntry === observedEntry else {
                return
            }
            render(entry: observedEntry)
        }
    }

    private func renderObservedEntry() {
        guard let observedEntry else {
            return
        }
        render(entry: observedEntry)
    }

    private func configureStaticViews() {
        statusIndicatorView.accessibilityIdentifier = "WebInspector.Network.List.StatusIndicator"
        statusIndicatorView.layer.cornerRadius = 4

        fileTypeLabel.accessibilityIdentifier = "WebInspector.Network.List.FileTypeLabel"
        fileTypeLabel.textColor = .secondaryLabel
        fileTypeLabel.font = .preferredFont(forTextStyle: .footnote)
        fileTypeLabel.adjustsFontForContentSizeCategory = true

        contentConfiguration = Self.makeContentConfiguration()
        var background = UIBackgroundConfiguration.listCell()
        background.cornerRadius = 0
        backgroundConfiguration = background
        accessories = [
            .customView(
                configuration: .init(
                    customView: statusIndicatorView,
                    placement: .leading(),
                    reservedLayoutWidth: .custom(8),
                    maintainsFixedSize: true
                )
            ),
            .customView(
                configuration: .init(
                    customView: fileTypeLabel,
                    placement: .trailing(),
                    reservedLayoutWidth: .actual,
                    maintainsFixedSize: false
                )
            ),
            .disclosureIndicator(),
        ]

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.accessibilityIdentifier = "WebInspector.Network.List.Separator"
        separatorView.backgroundColor = .separator
        separatorView.isUserInteractionEnabled = false
        addSubview(separatorView)
        NSLayoutConstraint.activate([
            separatorView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale),
        ])
        setListPosition(.single)
    }

    private func render(
        displayName: String,
        statusSeverity: NetworkDisplay.StatusSeverity,
        fileTypeLabel: String
    ) {
        render(displayName: displayName)
        renderAccessories(statusSeverity: statusSeverity, fileTypeLabel: fileTypeLabel)
    }

    private func render(entry: NetworkListEntry) {
        let requests = entry.requests
        let representativeRequest = entry.representativeRequest
        let countSuffix = requests.count > 1 ? " ×\(requests.count)" : ""
        render(
            displayName: representativeRequest.displayName,
            statusSeverity: entry.statusSeverity,
            fileTypeLabel: representativeRequest.fileTypeLabel + countSuffix
        )
    }

    private func render(displayName: String) {
        var content = (contentConfiguration as? UIListContentConfiguration) ?? Self.makeContentConfiguration()
        guard content.text != displayName else {
            return
        }
        content.text = displayName
        contentConfiguration = content
    }

    private func renderAccessories(
        statusSeverity: NetworkDisplay.StatusSeverity,
        fileTypeLabel: String
    ) {
        let color = statusSeverity.color
        if statusIndicatorView.backgroundColor?.isEqual(color) != true {
            statusIndicatorView.backgroundColor = color
        }
        if self.fileTypeLabel.text != fileTypeLabel {
            self.fileTypeLabel.text = fileTypeLabel
        }
    }

    private func cancelEntryObservation() {
        entryObservation?.cancel()
        entryObservation = nil
    }

    private static func makeContentConfiguration() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.secondaryText = nil
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.textProperties.font = preferredDisplayNameFont(compatibleWith: nil)
        content.textProperties.adjustsFontForContentSizeCategory = true
        return content
    }

    package static func rowHeight(compatibleWith traitCollection: UITraitCollection) -> CGFloat {
        let content = makeContentConfiguration()
        let displayNameHeight = preferredDisplayNameFont(
            compatibleWith: traitCollection
        ).lineHeight * CGFloat(content.textProperties.numberOfLines)
        let accessoryHeight = max(
            UIFont.preferredFont(
                forTextStyle: .footnote,
                compatibleWith: traitCollection
            ).lineHeight,
            20
        )
        return ceil(max(
            44,
            content.directionalLayoutMargins.top
                + max(displayNameHeight, accessoryHeight)
                + content.directionalLayoutMargins.bottom
        ))
    }

    private static func preferredDisplayNameFont(
        compatibleWith traitCollection: UITraitCollection?
    ) -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: .subheadline,
            compatibleWith: traitCollection
        ).addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold],
        ])
        return UIFont(descriptor: descriptor, size: 0)
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

    package var hasActiveRequestObservationForTesting: Bool {
        entryObservation != nil
    }

    package var entryObservationForTesting: PortableObservationTracking.Token? {
        entryObservation
    }

    package var observedEntryForTesting: NetworkListEntry? {
        observedEntry
    }

    package var contentNumberOfLinesForTesting: Int? {
        (contentConfiguration as? UIListContentConfiguration)?.textProperties.numberOfLines
    }

    package var separatorViewForTesting: UIView {
        separatorView
    }

    package var listPositionForTesting: ListPosition {
        listPosition
    }

    package var backgroundCornerRadiusForTesting: CGFloat? {
        backgroundConfiguration?.cornerRadius
    }
}
#endif
#endif
