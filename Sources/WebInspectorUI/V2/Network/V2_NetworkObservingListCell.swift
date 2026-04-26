import ObservationBridge
import WebInspectorEngine

#if canImport(UIKit)
import UIKit

@MainActor
final class V2_NetworkObservingListCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []
    private let statusIndicatorView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    private let fileTypeLabel = UILabel()
#if DEBUG
    private(set) var fileTypeLabelTextForTesting: String?
    private(set) var statusIndicatorColorForTesting: UIColor?
#endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
#if DEBUG
        fileTypeLabelTextForTesting = nil
        statusIndicatorColorForTesting = nil
#endif
    }

    isolated deinit {
        observationHandles.removeAll()
    }

    func bind(item: NetworkEntry) {
        observationHandles.removeAll()
        render(displayName: item.displayName)
        renderAccessories(item: item)

        item.observe([\.fileTypeLabel, \.statusSeverity]) { [weak self, weak item] in
            guard let item else {
                return
            }
            self?.renderAccessories(item: item)
        }
        .store(in: &observationHandles)
    }
    
    private func configureStaticViews() {
        statusIndicatorView.layer.cornerRadius = 4

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
            .disclosureIndicator()
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

    private func renderAccessories(item: NetworkEntry) {
        let statusColor = item.statusSeverity.color
        statusIndicatorView.backgroundColor = statusColor
        fileTypeLabel.text = item.fileTypeLabel
#if DEBUG
        fileTypeLabelTextForTesting = item.fileTypeLabel
        statusIndicatorColorForTesting = statusColor
#endif
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
