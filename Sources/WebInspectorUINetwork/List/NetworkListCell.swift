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
    private weak var observedEntry: NetworkEntry?
    private var isRenderingActive = true
#if DEBUG
    private var renderCountStorageForTesting = 0
#endif

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

    package func bind(entry: NetworkEntry, renderingActive: Bool) {
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
                startEntryObservationIfNeeded()
            }
            return
        }

        isRenderingActive = isActive
        if isActive {
            renderObservedEntry()
            startEntryObservationIfNeeded()
        } else {
            cancelEntryObservation()
        }
    }

    package func unbind() {
        cancelEntryObservation()
        observedEntry = nil
        render(displayName: "", statusSeverity: .neutral, fileTypeLabel: "")
    }

    private func startEntryObservationIfNeeded() {
        guard entryObservation == nil,
              observedEntry != nil else {
            return
        }
        entryObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self,
                  self.isRenderingActive else {
                return
            }
            self.renderObservedEntry()
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

    private func render(entry: NetworkEntry) {
#if DEBUG
        renderCountStorageForTesting += 1
#endif
        let groupSuffix = entry.requestIDs.count > 1 ? " ×\(entry.requestIDs.count)" : ""
        render(
            displayName: NetworkDisplay.URLSummary(url: entry.url).displayName,
            statusSeverity: statusSeverity(for: entry),
            fileTypeLabel: NetworkDisplay.fileTypeLabel(
                mimeType: entry.mimeType,
                resourceTypeRawValue: entry.resourceType?.rawValue,
                urlSummary: NetworkDisplay.URLSummary(url: entry.url)
            ) + groupSuffix
        )
    }

    private func statusSeverity(for entry: NetworkEntry) -> NetworkDisplay.StatusSeverity {
        switch entry.statusSeverity {
        case .neutral:
            .neutral
        case .success:
            .success
        case .notice:
            .notice
        case .warning:
            .warning
        case .error:
            .error
        }
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

    package var requestObservationForTesting: PortableObservationTracking.Token? {
        entryObservation
    }

    package var renderCountForTesting: Int {
        renderCountStorageForTesting
    }
}
#endif
#endif
