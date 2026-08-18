#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
final class NetworkHeadersTextView: UIView {
    private struct SectionRule {
        var range: NSRange
        var kind: NetworkHeadersTextSectionRuleKind
    }

    static let requestPreviewTagIdentifier = "WebInspector.Network.Headers.RequestPreview"
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
    private var renderedSignature: NetworkHeadersTextDocumentSignature?
    private var renderedRequests: [NetworkRequest] = []
    private weak var renderedActiveRequest: NetworkRequest?
    var requestPreviewAction: (@MainActor () -> Void)?
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

    func render(request: NetworkRequest, activeRequest: NetworkRequest) {
        render(requests: [request], activeRequest: activeRequest)
    }

    func render(requests: [NetworkRequest], activeRequest: NetworkRequest) {
        render(
            requests: requests,
            activeRequest: activeRequest,
            forceDocumentAssignment: false
        )
    }

    private func render(
        requests: [NetworkRequest],
        activeRequest: NetworkRequest,
        forceDocumentAssignment: Bool
    ) {
        precondition(requests.isEmpty == false, "Network headers require at least one request.")
        precondition(requests.contains { $0 === activeRequest })
        renderedRequests = requests
        renderedActiveRequest = activeRequest
        let document = NetworkHeadersTextDocumentBuilder(
            requests: requests,
            activeRequest: activeRequest,
            traitCollection: traitCollection
        ).makeDocument()
        if forceDocumentAssignment == false, renderedSignature == document.signature {
            updateSectionRuleRuns()
            return
        }

        renderedSignature = document.signature
        sectionRules = document.sectionRules.map { SectionRule(range: $0.range, kind: $0.kind) }
        let selectedRange = textView.selectedRange
        textView.attributedText = document.attributedString
        textView.selectedRange = clamped(selectedRange, toUTF16Length: document.attributedString.length)
#if DEBUG
        attributedTextAssignmentCount += 1
#endif
        updateSectionRuleRuns()
    }

    func clear() {
        renderedRequests = []
        renderedActiveRequest = nil
        renderedSignature = nil
        sectionRules = []
        textView.attributedText = NSAttributedString()
        updateSectionRuleRuns()
    }

    var contentScrollView: UIScrollView {
        textView
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
        guard renderedRequests.isEmpty == false else {
            return
        }
        guard let renderedActiveRequest else {
            preconditionFailure("Rendered Network headers must retain an active request.")
        }
        render(
            requests: renderedRequests,
            activeRequest: renderedActiveRequest,
            forceDocumentAssignment: true
        )
    }

    private func updateSectionRuleRuns() {
        textView.layoutIfNeeded()
        ruleOverlayView.ruleRuns = sectionRules.compactMap { rule in
            guard let rect = sectionRuleRect(for: rule.range) else {
                return nil
            }
            return NetworkHeadersRuleOverlayView.RuleRun(
                rect: rect,
                color: rule.kind.color.resolvedColor(with: traitCollection).cgColor
            )
        }
    }

    private func clamped(_ range: NSRange, toUTF16Length length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let selectionLength = min(max(0, range.length), length - location)
        return NSRange(location: location, length: selectionLength)
    }

    private func sectionRuleRect(for range: NSRange) -> CGRect? {
        let rects = textSegmentRects(for: range)
        guard let firstRect = rects.first else {
            return nil
        }
        let unionRect = rects.dropFirst().reduce(firstRect) { partialResult, rect in
            partialResult.union(rect)
        }
        let ruleX: CGFloat
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            ruleX = textView.textContainerInset.left
                + unionRect.maxX
                + Self.ruleGap
                - Self.ruleWidth
                - textView.contentOffset.x
        } else {
            ruleX = textView.textContainerInset.left
                + unionRect.minX
                - Self.ruleGap
                - textView.contentOffset.x
        }
        return CGRect(
            x: ruleX,
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
    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case .tag(Self.requestPreviewTagIdentifier) = textItem.content else {
            return defaultAction
        }
        let title = String(
            localized: "network.headers.request_data.view_preview",
            defaultValue: "View Request Preview",
            bundle: WebInspectorUILocalization.bundle
        )
        return UIAction(title: title) { [weak self] _ in
            self?.requestPreviewAction?()
        }
    }

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

#if DEBUG
extension NetworkHeadersTextView {
    var renderedTextForTesting: String {
        textView.attributedText.string
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

    var requestPreviewTagRangesForTesting: [NSRange] {
        let attributedText = AttributedString(textView.attributedText)
        return attributedText.runs.compactMap { run in
            guard run.uiKit.textItemTag == Self.requestPreviewTagIdentifier else {
                return nil
            }
            let prefix = String(attributedText.characters[..<run.range.lowerBound])
            let value = String(attributedText.characters[run.range])
            return NSRange(location: prefix.utf16.count, length: value.utf16.count)
        }
    }

    var sectionRuleRectsForTesting: [CGRect] {
        ruleOverlayView.ruleRuns.map(\.rect)
    }

    var effectiveLayoutDirectionForTesting: UIUserInterfaceLayoutDirection {
        effectiveUserInterfaceLayoutDirection
    }

    var requestPreviewFontPointSizeForTesting: CGFloat? {
        let attributedText = AttributedString(textView.attributedText)
        return attributedText.runs.first(where: {
            $0.uiKit.textItemTag == Self.requestPreviewTagIdentifier
        })?.uiKit.font?.pointSize
    }

    func activateRequestPreviewForTesting() {
        requestPreviewAction?()
    }
}
#endif
#endif
