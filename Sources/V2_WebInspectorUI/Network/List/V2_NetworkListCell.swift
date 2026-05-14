#if canImport(UIKit)
import ObservationBridge
import UIKit
import V2_WebInspectorCore

@MainActor
package final class V2_NetworkListCell: UICollectionViewListCell {
    private let observationScope = ObservationScope()
    private let statusIndicatorView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    private let fileTypeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        observationScope.cancelAll()
    }

    package func bind(request: NetworkRequest) {
        render(displayName: request.displayName)
        renderAccessories(request: request)

        observationScope.update {
            request.observe([\.request, \.response, \.resourceType, \.state]) { [weak self, weak request] in
                guard let request else {
                    return
                }
                self?.render(displayName: request.displayName)
                self?.renderAccessories(request: request)
            }
            .store(in: observationScope)
        }
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

    private func render(displayName: String) {
        var content = (contentConfiguration as? UIListContentConfiguration) ?? Self.makeContentConfiguration()
        guard content.text != displayName else {
            return
        }
        content.text = displayName
        contentConfiguration = content
    }

    private func renderAccessories(request: NetworkRequest) {
        statusIndicatorView.backgroundColor = request.statusSeverity.color
        fileTypeLabel.text = request.fileTypeLabel
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
