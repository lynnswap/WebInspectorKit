import Foundation
import WebInspectorEngine

#if canImport(AppKit)
import AppKit

@MainActor
enum WINetworkAppKitViewFactory {
    static func makeLabel(
        _ text: String = "",
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        color: NSColor = .labelColor,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        numberOfLines: Int = 1,
        selectable: Bool = false,
        alignment: NSTextAlignment = .natural
    ) -> NSTextField {
        let label = numberOfLines == 1
            ? NSTextField(labelWithString: text)
            : NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.isSelectable = selectable
        label.lineBreakMode = lineBreakMode
        label.maximumNumberOfLines = numberOfLines
        label.cell?.lineBreakMode = lineBreakMode
        label.cell?.wraps = numberOfLines != 1
        label.cell?.usesSingleLineMode = numberOfLines == 1
        return label
    }

    static func makeSectionTitleLabel(_ text: String) -> NSTextField {
        makeLabel(
            text,
            font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
        )
    }

    static func makeSecondaryLabel(
        _ text: String = "",
        monospaced: Bool = false,
        numberOfLines: Int = 1,
        selectable: Bool = false,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSTextField {
        let font: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            : .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize)
        return makeLabel(
            text,
            font: font,
            color: .secondaryLabelColor,
            lineBreakMode: lineBreakMode,
            numberOfLines: numberOfLines,
            selectable: selectable
        )
    }

    static func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    static func makeEmptyStateView(
        title: String,
        description: String,
        symbolName: String = "waveform.path.ecg.rectangle"
    ) -> NSStackView {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28)
        ])

        let titleLabel = makeLabel(
            title,
            font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold),
            color: .secondaryLabelColor,
            numberOfLines: 2,
            alignment: .center
        )
        let descriptionLabel = makeSecondaryLabel(
            description,
            numberOfLines: 3,
            lineBreakMode: .byWordWrapping
        )
        descriptionLabel.alignment = .center

        let stack = NSStackView(views: [imageView, titleLabel, descriptionLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        return stack
    }

    static func makeMetricView(symbolName: String, text: String, color: NSColor = .secondaryLabelColor) -> NSStackView {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = color
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))

        let label = makeLabel(
            text,
            font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize),
            color: color
        )

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        return stack
    }
}

@MainActor
func networkStatusColor(for severity: NetworkStatusSeverity) -> NSColor {
    switch severity {
    case .success:
        return .systemGreen
    case .notice:
        return .systemYellow
    case .warning:
        return .systemOrange
    case .error:
        return .systemRed
    case .neutral:
        return .secondaryLabelColor
    }
}

@MainActor
func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
    let headerValue: String?
    switch body.role {
    case .request:
        headerValue = entry.requestHeaders["content-type"]
    case .response:
        headerValue = entry.responseHeaders["content-type"] ?? entry.mimeType
    }
    if let headerValue, !headerValue.isEmpty {
        let trimmed = headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        return trimmed ?? headerValue
    }
    return body.kind.rawValue.uppercased()
}

@MainActor
func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
    if let size = body.size {
        return size
    }
    switch body.role {
    case .request:
        return entry.requestBodyBytesSent
    case .response:
        return entry.decodedBodyLength ?? entry.encodedBodyLength
    }
}

func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

private func decodedBodyText(from body: NetworkBody) -> String? {
    guard let rawText = body.full ?? body.preview, !rawText.isEmpty else {
        return nil
    }
    guard body.isBase64Encoded == false else {
        guard let data = Data(base64Encoded: rawText) else {
            return rawText
        }
        return String(data: data, encoding: .utf8) ?? rawText
    }
    return rawText
}

final class WINetworkFlippedContentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
#endif
