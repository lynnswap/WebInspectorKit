#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorRuntime

@MainActor
final class V2_NetworkEntryOverviewCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []

    override func prepareForReuse() {
        super.prepareForReuse()
        observationHandles.removeAll()
    }

    isolated deinit {
        observationHandles.removeAll()
    }

    func bind(entry: NetworkEntry) {
        observationHandles.removeAll()

        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.numberOfLines = 1
        content.secondaryText = entry.url
        content.secondaryTextProperties.numberOfLines = 4
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = .label
        content.textToSecondaryTextVerticalPadding = 8
        content.attributedText = makeMetricsAttributedText(for: entry)
        contentConfiguration = content

        entry.observe(\.url) { [weak self] newURL in
            self?.renderURL(newURL)
        }
        .store(in: &observationHandles)

        entry.observe([\.method, \.statusCode, \.statusText, \.phase, \.duration, \.encodedBodyLength]) {
            [weak self, weak entry] in
            guard let self, let entry else {
                return
            }
            self.renderMetrics(self.makeMetricsAttributedText(for: entry))
        }
        .store(in: &observationHandles)
    }

    private func renderURL(_ url: String) {
        guard var content = contentConfiguration as? UIListContentConfiguration else {
            return
        }
        content.secondaryText = url
        contentConfiguration = content
    }

    private func renderMetrics(_ metricsText: NSAttributedString) {
        guard var content = contentConfiguration as? UIListContentConfiguration else {
            return
        }
        content.attributedText = metricsText
        contentConfiguration = content
    }

    private func makeMetricsAttributedText(for entry: NetworkEntry) -> NSAttributedString {
        let metricsFont = UIFont.preferredFont(forTextStyle: .footnote)
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(attachment: makeStatusBadgeAttachment(for: entry, baselineFont: metricsFont)))

        if let duration = entry.duration {
            appendMetric(
                symbolName: "clock",
                text: entry.durationText(for: duration),
                to: attributed,
                font: metricsFont,
                color: .secondaryLabel
            )
        }
        if let encodedBodyLength = entry.encodedBodyLength {
            appendMetric(
                symbolName: "arrow.down.to.line",
                text: entry.sizeText(for: encodedBodyLength),
                to: attributed,
                font: metricsFont,
                color: .secondaryLabel
            )
        }
        return attributed
    }

    private func makeStatusBadgeAttachment(for entry: NetworkEntry, baselineFont: UIFont) -> NSTextAttachment {
        let tint = entry.statusSeverity.color
        let badgeFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .semibold
            )
        )
        let badgeText = entry.statusLabel as NSString
        let textSize = badgeText.size(withAttributes: [.font: badgeFont])
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4
        let badgeSize = CGSize(
            width: ceil(textSize.width + horizontalPadding * 2),
            height: ceil(textSize.height + verticalPadding * 2)
        )

        let badgeImage = UIGraphicsImageRenderer(size: badgeSize).image { _ in
            let rect = CGRect(origin: .zero, size: badgeSize)
            let cornerRadius = min(8, badgeSize.height / 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            tint.withAlphaComponent(0.14).setFill()
            path.fill()

            let textRect = CGRect(
                x: (badgeSize.width - textSize.width) / 2,
                y: (badgeSize.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            badgeText.draw(
                in: textRect,
                withAttributes: [
                    .font: badgeFont,
                    .foregroundColor: tint,
                ]
            )
        }

        let attachment = NSTextAttachment()
        attachment.image = badgeImage
        let baselineOffset = (baselineFont.capHeight - badgeSize.height) / 2
        attachment.bounds = CGRect(x: 0, y: baselineOffset, width: badgeSize.width, height: badgeSize.height)
        return attachment
    }

    private func appendMetric(
        symbolName: String,
        text: String,
        to attributed: NSMutableAttributedString,
        font: UIFont,
        color: UIColor
    ) {
        attributed.append(NSAttributedString(string: "  "))
        if let symbol = makeSymbolAttachment(symbolName: symbolName, baselineFont: font, tintColor: color) {
            attributed.append(symbol)
            attributed.append(NSAttributedString(string: " "))
        }
        attributed.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                ]
            )
        )
    }

    private func makeSymbolAttachment(
        symbolName: String,
        baselineFont: UIFont,
        tintColor: UIColor
    ) -> NSAttributedString? {
        let symbolConfiguration = UIImage.SymbolConfiguration(font: baselineFont)
        guard
            let symbolImage = UIImage(systemName: symbolName, withConfiguration: symbolConfiguration)?
                .withTintColor(tintColor, renderingMode: .alwaysOriginal)
        else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = symbolImage
        let symbolSize = symbolImage.size
        let baselineOffset = (baselineFont.capHeight - symbolSize.height) / 2
        attachment.bounds = CGRect(x: 0, y: baselineOffset, width: symbolSize.width, height: symbolSize.height)
        return NSAttributedString(attachment: attachment)
    }
}
#endif
