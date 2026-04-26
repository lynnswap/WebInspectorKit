import ObservationBridge
import WebInspectorEngine

#if canImport(UIKit)
import UIKit

@MainActor
final class V2_NetworkObservingListCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []
#if DEBUG
    private(set) var fileTypeLabelTextForTesting: String?
    private(set) var statusIndicatorColorForTesting: UIColor?
#endif

    override func prepareForReuse() {
        super.prepareForReuse()
        resetObservationHandles()
        contentConfiguration = nil
        accessories = []
#if DEBUG
        fileTypeLabelTextForTesting = nil
        statusIndicatorColorForTesting = nil
#endif
    }

    func bind(item: NetworkEntry) {
        resetObservationHandles()

        store(
            item.observe(\.displayName) { [weak self] displayName in
                self?.render(displayName: displayName)
            }
        )
        store(
            item.observe([\.fileTypeLabel, \.statusSeverity]) { [weak self, weak item] in
                guard let item else {
                    return
                }
                self?.renderAccessories(item: item)
            }
        )
    }

    private func resetObservationHandles() {
        observationHandles.removeAll()
    }

    private func store(_ observationHandle: ObservationHandle) {
        observationHandle.store(in: &observationHandles)
    }

    private func render(displayName: String) {
        var content = (contentConfiguration as? UIListContentConfiguration) ?? Self.makeContentConfiguration()
        content.text = displayName
        contentConfiguration = content
    }

    private func renderAccessories(item: NetworkEntry) {
        let statusColor = networkStatusColor(for: item.statusSeverity)
        accessories = [
            .customView(configuration: Self.statusIndicatorConfiguration(color: statusColor)),
            .label(
                text: item.fileTypeLabel,
                options: .init(
                    reservedLayoutWidth: .actual,
                    tintColor: .secondaryLabel,
                    font: .preferredFont(forTextStyle: .footnote),
                    adjustsFontForContentSizeCategory: true
                )
            ),
            .disclosureIndicator()
        ]
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

    private static func statusIndicatorConfiguration(color: UIColor) -> UICellAccessory.CustomViewConfiguration {
        let dotView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
        dotView.backgroundColor = color
        dotView.layer.cornerRadius = 4

        return .init(
            customView: dotView,
            placement: .leading(),
            reservedLayoutWidth: .custom(8),
            maintainsFixedSize: true
        )
    }
}
#endif
