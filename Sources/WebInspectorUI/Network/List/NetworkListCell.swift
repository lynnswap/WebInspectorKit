#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class NetworkListCell: UICollectionViewListCell {
    private let statusIndicatorView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    private let fileTypeLabel = UILabel()
    private var requestObservation: PortableObservationTracking.Token?
    private weak var observedRequest: NetworkRequest?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        requestObservation?.cancel()
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        cancelRequestObservation()
    }

    package func bind(request: NetworkRequest) {
        guard observedRequest !== request else {
            return
        }
        cancelRequestObservation()
        observedRequest = request
        requestObservation = withPortableContinuousObservation { [weak self, weak request] _ in
            guard let self,
                  let request,
                  self.observedRequest === request else {
                return
            }
            render(
                displayName: request.displayName,
                statusSeverity: request.statusSeverity,
                fileTypeLabel: request.fileTypeLabel
            )
        }
    }

    package func unbind() {
        cancelRequestObservation()
        render(displayName: "", statusSeverity: .neutral, fileTypeLabel: "")
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
        statusSeverity: NetworkRequest.Display.StatusSeverity,
        fileTypeLabel: String
    ) {
        render(displayName: displayName)
        renderAccessories(statusSeverity: statusSeverity, fileTypeLabel: fileTypeLabel)
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
        statusSeverity: NetworkRequest.Display.StatusSeverity,
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

    private func cancelRequestObservation() {
        requestObservation?.cancel()
        requestObservation = nil
        observedRequest = nil
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
#endif
