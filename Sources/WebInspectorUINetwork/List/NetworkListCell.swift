#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class NetworkListCell: UICollectionViewListCell {
    private let statusIndicatorView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    private let fileTypeLabel = UILabel()
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
        content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
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

    package var hasActiveRequestObservationForTesting: Bool {
        entryObservation != nil
    }
}
#endif
#endif
