#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
final class NetworkHeadersTextView: UIView {
    private struct SectionRule {
        var range: NSRange
        var color: UIColor
    }

    private static let textInsets = NetworkHeadersWebKitStyle.textInsets
    private static let ruleWidth = NetworkHeadersWebKitStyle.ruleWidth
    private static let ruleGap = NetworkHeadersWebKitStyle.ruleGap

    private lazy var textView: UITextView = {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .automatic
        textView.delegate = self
        textView.keyboardDismissMode = .onDrag
        textView.textContainerInset = Self.textInsets
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.accessibilityIdentifier = "WebInspector.Network.HeadersTextView.Text"
        return textView
    }()
    private lazy var ruleOverlayView: NetworkHeadersRuleOverlayView = {
        let view = NetworkHeadersRuleOverlayView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    private var sectionRules: [SectionRule] = []
    private var renderedText = ""
    private weak var renderedRequest: NetworkRequest?
#if DEBUG
    private var attributedTextAssignmentCount = 0
#endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTextSystem()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSectionRuleRuns()
    }

    func render(request: NetworkRequest) {
        render(request: request, forceDocumentAssignment: false)
    }

    private func render(
        request: NetworkRequest,
        forceDocumentAssignment: Bool
    ) {
        renderedRequest = request
        let document = NetworkHeadersTextDocumentBuilder(request: request).makeDocument()
        let documentText = document.attributedString.string
        if forceDocumentAssignment == false, renderedText == documentText {
            updateSectionRuleRuns()
            return
        }

        renderedText = documentText
        sectionRules = document.sectionRules.map { SectionRule(range: $0.range, color: $0.color) }
        textView.attributedText = document.attributedString
#if DEBUG
        attributedTextAssignmentCount += 1
#endif
        updateSectionRuleRuns()
    }

    func clear() {
        renderedRequest = nil
        renderedText = ""
        sectionRules = []
        textView.attributedText = NSAttributedString()
        updateSectionRuleRuns()
    }

    private func configureTextSystem() {
        backgroundColor = .clear
        accessibilityIdentifier = "WebInspector.Network.HeadersTextView"

        addSubview(textView)
        addSubview(ruleOverlayView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ruleOverlayView.topAnchor.constraint(equalTo: topAnchor),
            ruleOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            ruleOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ruleOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (self: NetworkHeadersTextView, _) in
            self.rerenderIfNeeded()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: NetworkHeadersTextView, _) in
            self.rerenderIfNeeded()
        }
    }

    private func rerenderIfNeeded() {
        guard let renderedRequest else {
            return
        }
        render(request: renderedRequest, forceDocumentAssignment: true)
    }

    private func updateSectionRuleRuns() {
        textView.layoutIfNeeded()
        ruleOverlayView.ruleRuns = sectionRules.compactMap { rule in
            guard let rect = sectionRuleRect(for: rule.range) else {
                return nil
            }
            return NetworkHeadersRuleOverlayView.RuleRun(
                rect: rect,
                color: rule.color.resolvedColor(with: traitCollection).cgColor
            )
        }
    }

    private func sectionRuleRect(for range: NSRange) -> CGRect? {
        let rects = textSegmentRects(for: range)
        guard let firstRect = rects.first else {
            return nil
        }
        let unionRect = rects.dropFirst().reduce(firstRect) { partialResult, rect in
            partialResult.union(rect)
        }
        return CGRect(
            x: textView.textContainerInset.left + unionRect.minX - Self.ruleGap - textView.contentOffset.x,
            y: textView.textContainerInset.top + unionRect.minY - textView.contentOffset.y,
            width: Self.ruleWidth,
            height: unionRect.height
        )
    }

    private func textSegmentRects(for range: NSRange) -> [CGRect] {
        guard let layoutManager = textView.textLayoutManager,
              let textRange = textRange(for: range)
        else {
            return []
        }

        layoutManager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: [.rangeNotRequired]
        ) { _, rect, _, _ in
            rects.append(rect)
            return true
        }
        return rects
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        guard let contentStorage = textView.textLayoutManager?.textContentManager else {
            return nil
        }
        let length = textView.textStorage.length
        let location = min(max(0, range.location), length)
        let upperBound = min(max(location, range.location + range.length), length)
        guard let start = contentStorage.location(
            contentStorage.documentRange.location,
            offsetBy: location
        ),
              let end = contentStorage.location(start, offsetBy: upperBound - location)
        else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}

extension NetworkHeadersTextView: UITextViewDelegate {
    nonisolated func scrollViewDidScroll(_ scrollView: UIScrollView) {
        MainActor.assumeIsolated {
            updateSectionRuleRuns()
        }
    }
}

private final class NetworkHeadersRuleOverlayView: UIView {
    struct RuleRun {
        var rect: CGRect
        var color: CGColor
    }

    var ruleRuns: [RuleRun] = [] {
        didSet {
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        for ruleRun in ruleRuns where ruleRun.rect.intersects(rect) {
            context.saveGState()
            context.setFillColor(ruleRun.color)
            context.fill(ruleRun.rect)
            context.restoreGState()
        }
    }
}

private struct NetworkHeadersTextSectionRule {
    var range: NSRange
    var color: UIColor
}

private struct NetworkHeadersTextDocument {
    var attributedString: NSAttributedString
    var sectionRules: [NetworkHeadersTextSectionRule]
}

@MainActor
private struct NetworkHeadersTextDocumentBuilder {
    private enum RowStyle {
        case summary
        case header
        case pseudoHeader
        case message
    }

    private struct Row {
        var key: String
        var value: String?
        var style: RowStyle
    }

    private struct Section {
        var title: String
        var rows: [Row]
        var ruleColor: UIColor
    }

    var request: NetworkRequest

    func makeDocument() -> NetworkHeadersTextDocument {
        let text = NSMutableAttributedString()
        var rules: [NetworkHeadersTextSectionRule] = []
        for section in sections() where section.rows.isEmpty == false {
            append(section: section, to: text, rules: &rules)
        }
        return NetworkHeadersTextDocument(attributedString: text, sectionRules: rules)
    }

    private func sections() -> [Section] {
        [
            summarySection(),
            requestSection(),
            responseSection(),
        ].compactMap { $0 }
    }

    private func summarySection() -> Section {
        var rows: [Row] = [
            Row(key: String(localized: "network.headers.summary.url", defaultValue: "URL", bundle: .module), value: request.request.url, style: .summary),
            Row(key: String(localized: "network.headers.summary.status", defaultValue: "Status", bundle: .module), value: statusText(), style: .summary),
            Row(key: String(localized: "network.headers.summary.source", defaultValue: "Source", bundle: .module), value: sourceText(), style: .summary),
        ]
        if let remoteAddress = request.metrics?.remoteAddress, remoteAddress.isEmpty == false {
            rows.append(
                Row(
                    key: String(localized: "network.headers.summary.address", defaultValue: "Address", bundle: .module),
                    value: remoteAddress,
                    style: .summary
                )
            )
        }
        return Section(
            title: String(localized: "network.detail.section.overview", bundle: .module),
            rows: rows,
            ruleColor: NetworkHeadersWebKitStyle.networkSystemColor
        )
    }

    private func requestSection() -> Section {
        let headers = request.request.headers
        var rows: [Row] = requestProtocolRows()
        rows.append(contentsOf: headerRows(headers))
        if rows.isEmpty {
            rows.append(
                Row(
                    key: String(localized: "network.headers.request.empty", defaultValue: "No request headers", bundle: .module),
                    value: nil,
                    style: .message
                )
            )
        }
        return Section(
            title: String(localized: "network.section.request", bundle: .module),
            rows: rows,
            ruleColor: NetworkHeadersWebKitStyle.networkHeaderColor
        )
    }

    private func responseSection() -> Section? {
        guard request.response != nil else {
            return nil
        }
        let headers = request.response?.headers ?? [:]
        var rows: [Row] = responseProtocolRows()
        rows.append(contentsOf: headerRows(headers))
        if rows.isEmpty {
            rows.append(
                Row(
                    key: String(localized: "network.headers.response.empty", defaultValue: "No response headers", bundle: .module),
                    value: nil,
                    style: .message
                )
            )
        }
        return Section(
            title: String(localized: "network.section.response", bundle: .module),
            rows: rows,
            ruleColor: NetworkHeadersWebKitStyle.networkHeaderColor
        )
    }

    private func requestProtocolRows() -> [Row] {
        let protocolName = request.metrics?.networkProtocol ?? ""
        let components = URLComponents(string: request.request.url)
        if protocolName == "h2" {
            return [
                Row(key: ":method", value: request.request.method, style: .pseudoHeader),
                Row(key: ":scheme", value: components?.scheme, style: .pseudoHeader),
                Row(key: ":authority", value: authority(from: components), style: .pseudoHeader),
                Row(key: ":path", value: path(from: components), style: .pseudoHeader),
            ].compactMap { row in
                guard row.value?.isEmpty == false else {
                    return nil
                }
                return row
            }
        }
        let path = path(from: components) ?? "/"
        let suffix = protocolName.hasPrefix("http/1") ? " \(protocolName.uppercased())" : ""
        return [
            Row(key: "\(request.request.method) \(path)\(suffix)", value: nil, style: .pseudoHeader),
        ]
    }

    private func responseProtocolRows() -> [Row] {
        guard let response = request.response else {
            return []
        }
        let protocolName = request.metrics?.networkProtocol ?? ""
        if protocolName == "h2" {
            return [Row(key: ":status", value: "\(response.status)", style: .pseudoHeader)]
        }
        if protocolName.hasPrefix("http/1") {
            let suffix = response.statusText.isEmpty ? "" : " \(response.statusText)"
            return [Row(key: "\(protocolName.uppercased()) \(response.status)\(suffix)", value: nil, style: .pseudoHeader)]
        }
        let suffix = response.statusText.isEmpty ? "" : " \(response.statusText)"
        return [Row(key: "\(response.status)\(suffix)", value: nil, style: .pseudoHeader)]
    }

    private func headerRows(_ headers: [String: String]) -> [Row] {
        headers
            .map { Row(key: $0.key, value: $0.value, style: .header) }
            .sorted {
                let nameComparison = $0.key.localizedCaseInsensitiveCompare($1.key)
                if nameComparison == .orderedSame {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return nameComparison == .orderedAscending
            }
    }

    private func statusText() -> String {
        guard let response = request.response else {
            return "-"
        }
        let suffix = response.statusText.isEmpty ? "" : " \(response.statusText)"
        return "\(response.status)\(suffix)"
    }

    private func sourceText() -> String {
        guard let source = request.response?.source else {
            return "-"
        }
        switch source {
        case .network:
            return String(localized: "network.headers.source.network", defaultValue: "Network", bundle: .module)
        case .memoryCache:
            return String(localized: "network.headers.source.memory_cache", defaultValue: "Memory Cache", bundle: .module)
        case .diskCache:
            return String(localized: "network.headers.source.disk_cache", defaultValue: "Disk Cache", bundle: .module)
        case .serviceWorker:
            return String(localized: "network.headers.source.service_worker", defaultValue: "Service Worker", bundle: .module)
        case .inspectorOverride:
            return String(localized: "network.headers.source.local_override", defaultValue: "Local Override", bundle: .module)
        default:
            return source.rawValue
        }
    }

    private func authority(from components: URLComponents?) -> String? {
        guard let host = components?.host, host.isEmpty == false else {
            return nil
        }
        guard let port = components?.port else {
            return host
        }
        return "\(host):\(port)"
    }

    private func path(from components: URLComponents?) -> String? {
        guard let components else {
            return nil
        }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, query.isEmpty == false {
            path += "?\(query)"
        }
        return path
    }

    private func append(
        section: Section,
        to text: NSMutableAttributedString,
        rules: inout [NetworkHeadersTextSectionRule]
    ) {
        if text.length > 0 {
            text.append(NSAttributedString(string: "\n", attributes: rowAttributes(style: .message).value))
        }

        text.append(NSAttributedString(string: section.title + "\n", attributes: sectionTitleAttributes()))
        let ruleStart = text.length
        for row in section.rows {
            append(row: row, to: text)
        }
        let ruleLength = text.length - ruleStart
        if ruleLength > 0 {
            rules.append(NetworkHeadersTextSectionRule(range: NSRange(location: ruleStart, length: ruleLength), color: section.ruleColor))
        }
    }

    private func append(row: Row, to text: NSMutableAttributedString) {
        let attributes = rowAttributes(style: row.style)
        text.append(NSAttributedString(string: row.key, attributes: attributes.key))
        if let value = row.value, value.isEmpty == false {
            text.append(NSAttributedString(string: ": ", attributes: attributes.key))
            text.append(NSAttributedString(string: value, attributes: attributes.value))
        }
        text.append(NSAttributedString(string: "\n", attributes: attributes.value))
    }

    private func sectionTitleAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.paragraphSpacing = NetworkHeadersWebKitStyle.sectionTitleBottomSpacing
        return [
            .font: NetworkHeadersWebKitStyle.sectionTitleFont,
            .foregroundColor: NetworkHeadersWebKitStyle.textColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func rowAttributes(
        style: RowStyle
    ) -> (key: [NSAttributedString.Key: Any], value: [NSAttributedString.Key: Any]) {
        let font = NetworkHeadersWebKitStyle.bodyFont
        let keyFont = NetworkHeadersWebKitStyle.keyFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.firstLineHeadIndent = NetworkHeadersWebKitStyle.rowFirstLineHeadIndent
        paragraphStyle.headIndent = NetworkHeadersWebKitStyle.rowWrappedLineHeadIndent
        paragraphStyle.paragraphSpacingBefore = NetworkHeadersWebKitStyle.rowVerticalPadding
        paragraphStyle.paragraphSpacing = NetworkHeadersWebKitStyle.rowVerticalPadding

        let keyColor: UIColor
        switch style {
        case .summary:
            keyColor = NetworkHeadersWebKitStyle.networkSystemColor
        case .header:
            keyColor = NetworkHeadersWebKitStyle.networkHeaderColor
        case .pseudoHeader:
            keyColor = NetworkHeadersWebKitStyle.networkPseudoHeaderColor
        case .message:
            keyColor = NetworkHeadersWebKitStyle.consoleSecondaryTextColor
        }

        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: keyFont,
            .foregroundColor: keyColor,
            .paragraphStyle: paragraphStyle,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style == .message
                ? NetworkHeadersWebKitStyle.consoleSecondaryTextColor
                : NetworkHeadersWebKitStyle.textColor,
            .paragraphStyle: paragraphStyle,
        ]
        return (keyAttributes, valueAttributes)
    }
}

private enum NetworkHeadersWebKitStyle {
    static let textInsets = UIEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
    static let ruleWidth: CGFloat = 2
    static let ruleGap = detailsTextPadding
    static let sectionTitleBottomSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 2
    private static let detailsMarginStart: CGFloat = 12
    private static let detailsTextPadding: CGFloat = 12
    private static let detailsValueIndent: CGFloat = 12
    static let rowFirstLineHeadIndent = detailsMarginStart + detailsTextPadding
    static let rowWrappedLineHeadIndent = rowFirstLineHeadIndent + detailsValueIndent

    static var bodyFont: UIFont {
        UIFont.preferredFont(forTextStyle: .callout)
    }

    static var keyFont: UIFont {
        UIFont.preferredFont(forTextStyle: .callout).withWeight(.medium)
    }

    static var sectionTitleFont: UIFont {
        UIFont.preferredFont(forTextStyle: .headline)
    }

    static var textColor: UIColor {
        dynamic(light: .black, dark: hsl(0, 0, 88))
    }

    static var consoleSecondaryTextColor: UIColor {
        dynamic(
            light: hsl(0, 0, 0, alpha: 0.33),
            dark: hsl(0, 0, 100, alpha: 0.45)
        )
    }

    static var networkSystemColor: UIColor {
        dynamic(light: hsl(79, 32, 50), dark: hsl(79, 95, 50))
    }

    static var networkHeaderColor: UIColor {
        hsl(204, 52, 55)
    }

    static var networkPseudoHeaderColor: UIColor {
        dynamic(light: hsl(312, 35, 51), dark: hsl(312, 55, 61))
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
    }

    private static func hsl(
        _ hue: CGFloat,
        _ saturation: CGFloat,
        _ lightness: CGFloat,
        alpha: CGFloat = 1
    ) -> UIColor {
        let hue = hue / 360
        let saturation = saturation / 100
        let lightness = lightness / 100
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let huePrime = hue * 6
        let secondary = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2

        let components: (red: CGFloat, green: CGFloat, blue: CGFloat)
        switch huePrime {
        case 0..<1:
            components = (chroma, secondary, 0)
        case 1..<2:
            components = (secondary, chroma, 0)
        case 2..<3:
            components = (0, chroma, secondary)
        case 3..<4:
            components = (0, secondary, chroma)
        case 4..<5:
            components = (secondary, 0, chroma)
        default:
            components = (chroma, 0, secondary)
        }

        return UIColor(
            red: components.red + match,
            green: components.green + match,
            blue: components.blue + match,
            alpha: alpha
        )
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

#if DEBUG
extension NetworkHeadersTextView {
    var renderedTextForTesting: String {
        renderedText
    }

    var usesTextKit2ForTesting: Bool {
        textView.textLayoutManager != nil
    }

    var isSelectableForTesting: Bool {
        textView.isSelectable
    }

    var selectedRangeForTesting: NSRange {
        get {
            textView.selectedRange
        }
        set {
            textView.selectedRange = newValue
        }
    }

    var attributedTextAssignmentCountForTesting: Int {
        attributedTextAssignmentCount
    }
}
#endif
#endif
