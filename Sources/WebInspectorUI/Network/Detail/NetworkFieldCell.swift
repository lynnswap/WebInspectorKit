#if canImport(UIKit)
import UIKit

@MainActor
final class NetworkFieldCell: UICollectionViewListCell {
    private enum ConfigurationKind {
        case bodyMetadata
        case bodyLink
        case header
    }

    private var configurationKind: ConfigurationKind?

    func bindBodyMetadata(name: String, value: String) {
        let wasBodyMetadata = configurationKind == .bodyMetadata
        var configuration = wasBodyMetadata
            ? (contentConfiguration as? UIListContentConfiguration) ?? Self.makeBodyMetadataConfiguration()
            : Self.makeBodyMetadataConfiguration()
        configurationKind = .bodyMetadata

        guard !wasBodyMetadata || configuration.text != name || configuration.secondaryText != value else {
            return
        }

        configuration.text = name
        configuration.secondaryText = value
        contentConfiguration = configuration
        accessories = []
    }

    func bindBodyLink(title: String, isEnabled: Bool) {
        let wasBodyLink = configurationKind == .bodyLink
        var configuration = wasBodyLink
            ? (contentConfiguration as? UIListContentConfiguration) ?? Self.makeBodyLinkConfiguration()
            : Self.makeBodyLinkConfiguration()
        configurationKind = .bodyLink

        configuration.text = title
        configuration.textProperties.color = isEnabled ? .label : .secondaryLabel
        contentConfiguration = configuration
        accessories = isEnabled ? [.disclosureIndicator()] : []
    }

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
        accessories = []
    }

    func clear() {
        configurationKind = nil
        contentConfiguration = nil
        accessories = []
    }

    private static func makeBodyMetadataConfiguration() -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.valueCell()
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .semibold
            )
        )
        configuration.textProperties.color = .secondaryLabel
        configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        configuration.secondaryTextProperties.color = .label
        return configuration
    }

    private static func makeBodyLinkConfiguration() -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.cell()
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .regular
            )
        )
        return configuration
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

}
#endif
