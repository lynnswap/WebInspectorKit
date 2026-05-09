#if canImport(UIKit)
import UIKit

@MainActor
final class NetworkEntryFieldCell: UICollectionViewListCell {
    private enum ConfigurationKind {
        case header
        case empty
    }

    private var configurationKind: ConfigurationKind?

    func bindHeader(name: String, value: String) {
        let wasHeader = configurationKind == .header
        var configuration = wasHeader
            ? (contentConfiguration as? UIListContentConfiguration) ?? Self.makeHeaderConfiguration()
            : Self.makeHeaderConfiguration()
        configurationKind = .header

        guard !wasHeader || configuration.text != name || configuration.secondaryText != value else {
            return
        }

        configuration.text = name
        configuration.secondaryText = value
        contentConfiguration = configuration
    }

    func bindEmptyHeaders() {
        let wasEmpty = configurationKind == .empty
        var configuration = wasEmpty
            ? (contentConfiguration as? UIListContentConfiguration) ?? Self.makeEmptyHeadersConfiguration()
            : Self.makeEmptyHeadersConfiguration()
        configurationKind = .empty

        let text = wiLocalized("network.headers.empty", default: "No headers")
        guard !wasEmpty || configuration.text != text else {
            return
        }

        configuration.text = text
        contentConfiguration = configuration
    }

    func clear() {
        configurationKind = nil
        contentConfiguration = nil
    }

    private static func makeHeaderConfiguration() -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.textProperties.numberOfLines = 1
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        configuration.textToSecondaryTextVerticalPadding = 8
        configuration.textProperties.color = .secondaryLabel
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
        configuration.secondaryTextProperties.color = .label
        return configuration
    }

    private static func makeEmptyHeadersConfiguration() -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.cell()
        configuration.textProperties.color = .secondaryLabel
        return configuration
    }
}
#endif
