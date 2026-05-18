#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore

@MainActor
package final class DOMElementStylesTextView: UIScrollView, @preconcurrency NSTextViewportLayoutControllerDelegate, UITextInput, UITextInteractionDelegate {
    package typealias ToggleAction = @MainActor (CSSPropertyIdentifier, Bool) -> Bool

    private struct StyleMembership: Equatable {
        var sections: [SectionMembership]
    }

    private struct SectionMembership: Equatable {
        var id: CSSStyleSectionIdentifier
        var properties: [PropertyIdentity]
    }

    private enum PropertyIdentity: Hashable {
        case identified(sectionID: CSSStyleSectionIdentifier, propertyID: CSSPropertyIdentifier)
        case object(sectionID: CSSStyleSectionIdentifier, objectID: ObjectIdentifier)

        var propertyID: CSSPropertyIdentifier? {
            if case let .identified(_, propertyID) = self {
                return propertyID
            }
            return nil
        }
    }

    private enum LineKind {
        case section(CSSStyleSection)
        case property(CSSProperty, PropertyIdentity)
        case closing(CSSStyleSectionIdentifier)
        case blank
    }

    private struct StyleLine {
        var kind: LineKind
        var text: String
        var range: NSRange
        var declarationRange: NSRange?

        var property: CSSProperty? {
            if case let .property(property, _) = kind {
                return property
            }
            return nil
        }

        var propertyIdentity: PropertyIdentity? {
            if case let .property(_, identity) = kind {
                return identity
            }
            return nil
        }
    }

    private static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let sectionFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    private static let lineSpacing: CGFloat = 4
    private static let textInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    private static let rowHeight: CGFloat = ceil(font.lineHeight + lineSpacing)
    private static let checkboxSideLength: CGFloat = floor(min(14, rowHeight - 6))
    private static let checkboxColumnWidth: CGFloat = checkboxSideLength + 6
    private static let characterWidth: CGFloat = {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }()
    private static let paragraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.minimumLineHeight = rowHeight
        paragraphStyle.maximumLineHeight = rowHeight
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        return paragraphStyle
    }()
    private static let propertyParagraphStyle: NSParagraphStyle = {
        let propertyParagraphStyle = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        propertyParagraphStyle.firstLineHeadIndent = checkboxColumnWidth
        propertyParagraphStyle.headIndent = checkboxColumnWidth
        return propertyParagraphStyle
    }()

    private let observationScope = ObservationScope()
    private let textContentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer()
    private let textContentView = DOMElementStylesTextContentView()
    private let fragmentViewMap = NSMapTable<NSTextLayoutFragment, DOMElementStylesTextLayoutFragmentView>.weakToWeakObjects()
    private var lastUsedFragmentViews: Set<DOMElementStylesTextLayoutFragmentView> = []
    private lazy var textSelectionInteraction: UITextInteraction = {
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.delegate = self
        interaction.textInput = self
        return interaction
    }()
    private lazy var textInputTokenizer = UITextInputStringTokenizer(textInput: self)

    private var nodeStyles: CSSNodeStyles?
    private var toggleAction: ToggleAction?
    private var lines: [StyleLine] = []
    private var propertyLineIndexByIdentity: [PropertyIdentity: Int] = [:]
    private var propertyByIdentity: [PropertyIdentity: CSSProperty] = [:]
    private var checkboxControlByIdentity: [PropertyIdentity: DOMElementStyleCheckboxControl] = [:]
    private var identityByCheckboxControlID: [ObjectIdentifier: PropertyIdentity] = [:]
    private var currentMembership = StyleMembership(sections: [])
    private var renderedText = ""
    private var measuredTextWidth: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var selectedTextNSRange = NSRange(location: 0, length: 0)
    private var markedTextNSRange: NSRange?
    private var markedTextStyleStorage: [NSAttributedString.Key: Any]?
    private var isInstallingObservations = false
    weak package var inputDelegate: UITextInputDelegate?
#if DEBUG
    private var rebuildTextStorageCallCount = 0
    private var incrementalPropertyUpdateCallCount = 0
#endif

    private var textStorage: NSTextStorage {
        guard let storage = textContentStorage.textStorage else {
            fatalError("DOMElementStylesTextView requires NSTextContentStorage-backed NSTextStorage")
        }
        return storage
    }

    override package init(frame: CGRect) {
        super.init(frame: frame)
        configureTextSystem()
        configureInteractions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package var canBecomeFirstResponder: Bool {
        true
    }

    override package func layoutSubviews() {
        super.layoutSubviews()
        if lastBoundsSize != bounds.size || textContentView.frame.isEmpty {
            lastBoundsSize = bounds.size
            updateTextLayoutGeometry()
        }
        layoutManager.textViewportLayoutController.layoutViewport()
        layoutCheckboxButtons()
    }

    package func bind(
        nodeStyles: CSSNodeStyles,
        onToggle: ToggleAction? = nil
    ) {
        toggleAction = onToggle
        guard self.nodeStyles !== nodeStyles else {
            reapplyAttributes()
            return
        }

        self.nodeStyles = nodeStyles
        rebuildContent()
        observeContent()
    }

    package func clear() {
        observationScope.cancelAll()
        nodeStyles = nil
        toggleAction = nil
        lines.removeAll(keepingCapacity: true)
        propertyLineIndexByIdentity.removeAll(keepingCapacity: true)
        propertyByIdentity.removeAll(keepingCapacity: true)
        removeCheckboxControls()
        currentMembership = StyleMembership(sections: [])
        renderedText = ""
        measuredTextWidth = 0
        selectedTextNSRange = NSRange(location: 0, length: 0)
        markedTextNSRange = nil
        textContentStorage.performEditingTransaction {
            textStorage.setAttributedString(NSAttributedString(string: ""))
        }
        resetTextFragmentViews()
        updateTextLayoutGeometry()
        setNeedsLayout()
    }

    package func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let scrollInsets = adjustedContentInset
        return CGRect(
            x: bounds.origin.x - scrollInsets.left - Self.textInsets.left,
            y: bounds.origin.y - scrollInsets.top - Self.textInsets.top,
            width: bounds.width + scrollInsets.left + scrollInsets.right + Self.textInsets.left + Self.textInsets.right,
            height: bounds.height + scrollInsets.top + scrollInsets.bottom + Self.textInsets.top + Self.textInsets.bottom
        )
    }

    package func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        lastUsedFragmentViews = Set(textContentView.subviews.compactMap { $0 as? DOMElementStylesTextLayoutFragmentView })
    }

    package func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        let layoutFrame = textLayoutFragment.layoutFragmentFrame
        let visibleTextRect = visibleTextRect()
        let surfaceFrame = CGRect(
            x: visibleTextRect.minX,
            y: layoutFrame.minY,
            width: max(visibleTextRect.width, 1),
            height: layoutFrame.height
        )
        let fragmentView: DOMElementStylesTextLayoutFragmentView
        if let cachedView = fragmentViewMap.object(forKey: textLayoutFragment) {
            fragmentView = cachedView
            lastUsedFragmentViews.remove(cachedView)
        } else {
            fragmentView = DOMElementStylesTextLayoutFragmentView(layoutFragment: textLayoutFragment, frame: surfaceFrame)
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }

        fragmentView.layoutFragmentDrawPoint = CGPoint(
            x: layoutFrame.minX - surfaceFrame.minX,
            y: layoutFrame.minY - surfaceFrame.minY
        )
        if !fragmentView.frame.wiIsNearlyEqual(to: surfaceFrame) {
            fragmentView.frame = surfaceFrame
            fragmentView.setNeedsDisplay()
        }
        if fragmentView.superview !== textContentView {
            textContentView.addSubview(fragmentView)
        }
    }

    package func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
        }
        lastUsedFragmentViews.removeAll()
        updateTextLayoutGeometry()
        layoutCheckboxButtons()
    }

    package func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        let contentPoint = convert(point, to: textContentView)
        guard !checkboxHitRect(at: contentPoint) else {
            return false
        }
        return true
    }

    override package func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return selectedTextNSRange.length > 0
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override package func copy(_ sender: Any?) {
        guard selectedTextNSRange.length > 0,
              let text = text(in: DOMElementStylesTextRange(range: selectedTextNSRange))
        else {
            return
        }
        UIPasteboard.general.string = text
    }

    private func configureTextSystem() {
        backgroundColor = .clear
        accessibilityIdentifier = "WebInspector.DOM.Element.StylesTextView"
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true
        showsHorizontalScrollIndicator = false
        keyboardDismissMode = .onDrag

        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        layoutManager.textContainer = textContainer
        layoutManager.textViewportLayoutController.delegate = self
        textContentStorage.addTextLayoutManager(layoutManager)
        textContentStorage.primaryTextLayoutManager = layoutManager

        addSubview(textContentView)
    }

    private func configureInteractions() {
        addInteraction(textSelectionInteraction)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (self: DOMElementStylesTextView, _) in
            self.reapplyAttributes()
        }
    }

    private func observeContent() {
        isInstallingObservations = true
        observationScope.update {
            guard let nodeStyles else {
                return
            }

            nodeStyles.observe(\.sections) { [weak self] _ in
                guard let self, !self.isInstallingObservations else {
                    return
                }
                rebuildIfMembershipChanged()
            }
            .store(in: observationScope)

            for section in nodeStyles.sections {
                section.observe([\.title, \.subtitle]) { [weak self] in
                    guard let self, !self.isInstallingObservations else {
                        return
                    }
                    guard sectionLineTextNeedsUpdate(section) else {
                        return
                    }
                    rebuildContent()
                    observeContent()
                }
                .store(in: observationScope)

                section.style.observe(\.cssProperties) { [weak self] _ in
                    guard let self, !self.isInstallingObservations else {
                        return
                    }
                    rebuildIfMembershipChanged()
                }
                .store(in: observationScope)

                for property in section.style.cssProperties {
                    let sectionID = section.id
                    property.observe([\.name, \.value, \.priority, \.text, \.status, \.isEditable]) { [weak self, weak property] in
                        guard let self, let property, !self.isInstallingObservations else {
                            return
                        }
                        updatePropertyLine(property, sectionID: sectionID)
                    }
                    .store(in: observationScope)
                }
            }
        }
        isInstallingObservations = false
    }

    private func rebuildIfMembershipChanged() {
        guard let nodeStyles else {
            return
        }
        guard membership(for: nodeStyles) != currentMembership else {
            return
        }
        rebuildContent()
        observeContent()
    }

    private func rebuildContent() {
        guard let nodeStyles else {
            clear()
            return
        }

        let result = buildLines(from: nodeStyles)
        lines = result.lines
        renderedText = result.text
        currentMembership = result.membership
        rebuildLookupTables()
        updateMeasuredTextWidth()
        clampTextSelectionAfterTextChange()

        let attributedText = NSMutableAttributedString(
            string: renderedText.isEmpty ? "\n" : renderedText,
            attributes: baseAttributes()
        )
        applyAttributes(to: attributedText, lines: lines)
        updateCheckboxButtons()
#if DEBUG
        rebuildTextStorageCallCount += 1
#endif
        textContentStorage.performEditingTransaction {
            textStorage.setAttributedString(attributedText)
        }
        resetTextFragmentViews()
        updateTextLayoutGeometry()
        setNeedsLayout()
    }

    private func buildLines(from nodeStyles: CSSNodeStyles) -> (
        lines: [StyleLine],
        text: String,
        membership: StyleMembership
    ) {
        var lines: [StyleLine] = []
        var text = ""

        func appendLine(
            _ lineText: String,
            kind: LineKind,
            declarationRangeOffset: Int? = nil,
            declarationLength: Int? = nil
        ) {
            if !text.isEmpty {
                text += "\n"
            }
            let location = (text as NSString).length
            let length = (lineText as NSString).length
            let declarationRange: NSRange?
            if let declarationRangeOffset, let declarationLength {
                declarationRange = NSRange(location: location + declarationRangeOffset, length: declarationLength)
            } else {
                declarationRange = nil
            }
            lines.append(StyleLine(
                kind: kind,
                text: lineText,
                range: NSRange(location: location, length: length),
                declarationRange: declarationRange
            ))
            text += lineText
        }

        for section in nodeStyles.sections where !section.style.cssProperties.isEmpty {
            appendLine(sectionHeaderText(for: section), kind: .section(section))
            for property in section.style.cssProperties {
                let identity = propertyIdentity(for: property, in: section.id)
                let declaration = declarationDisplayText(for: property)
                appendLine(
                    declaration,
                    kind: .property(property, identity),
                    declarationRangeOffset: 0,
                    declarationLength: (declaration as NSString).length
                )
            }
            appendLine("}", kind: .closing(section.id))
            appendLine("", kind: .blank)
        }

        if matchesLastBlankLine(lines) {
            let lastLine = lines.removeLast()
            text = (text as NSString).substring(to: max(lastLine.range.location - 1, 0))
        }

        return (lines, text, membership(for: nodeStyles))
    }

    private func matchesLastBlankLine(_ lines: [StyleLine]) -> Bool {
        guard let lastLine = lines.last else {
            return false
        }
        if case .blank = lastLine.kind {
            return true
        }
        return false
    }

    private func rebuildLookupTables() {
        propertyLineIndexByIdentity.removeAll(keepingCapacity: true)
        propertyByIdentity.removeAll(keepingCapacity: true)
        for (index, line) in lines.enumerated() {
            guard let property = line.property,
                  let identity = line.propertyIdentity else {
                continue
            }
            propertyLineIndexByIdentity[identity] = index
            propertyByIdentity[identity] = property
        }
        let removedIdentities = checkboxControlByIdentity.keys.filter { propertyByIdentity[$0] == nil }
        for identity in removedIdentities {
            guard let checkboxControl = checkboxControlByIdentity[identity] else {
                continue
            }
            identityByCheckboxControlID.removeValue(forKey: ObjectIdentifier(checkboxControl))
            checkboxControl.removeFromSuperview()
            checkboxControlByIdentity.removeValue(forKey: identity)
        }
    }

    private func updatePropertyLine(_ property: CSSProperty, sectionID: CSSStyleSectionIdentifier) {
        let identity = propertyIdentity(for: property, in: sectionID)
        guard let lineIndex = propertyLineIndexByIdentity[identity],
              lines.indices.contains(lineIndex) else {
            rebuildIfMembershipChanged()
            return
        }

        let declaration = declarationDisplayText(for: property)
        let replacementLength = (declaration as NSString).length
        var line = lines[lineIndex]
        let previousRange = line.range
        let delta = replacementLength - line.range.length

        if line.text != declaration {
            textContentStorage.performEditingTransaction {
                textStorage.replaceCharacters(in: line.range, with: declaration)
            }
            renderedText = (renderedText as NSString).replacingCharacters(in: line.range, with: declaration)
            line.text = declaration
            line.range.length = replacementLength
            line.declarationRange = NSRange(location: line.range.location, length: replacementLength)
            lines[lineIndex] = line

            if delta != 0, lineIndex + 1 < lines.count {
                for index in (lineIndex + 1)..<lines.count {
                    lines[index].range.location += delta
                    if lines[index].declarationRange != nil {
                        lines[index].declarationRange?.location += delta
                    }
                }
            }
            clampTextSelectionAfterTextChange()
        }

        updateMeasuredTextWidth()
        applyAttributes(to: lineIndex)
        updateCheckboxButton(for: property, identity: identity)
        invalidateTextLayout(including: NSUnionRange(previousRange, line.range))
        updateTextLayoutGeometry()
        setNeedsLayout()
#if DEBUG
        incrementalPropertyUpdateCallCount += 1
#endif
    }

    private func reapplyAttributes() {
        guard textStorage.length > 0 else {
            return
        }
        textStorage.setAttributes(baseAttributes(), range: NSRange(location: 0, length: textStorage.length))
        applyAttributes(to: textStorage, lines: lines)
        updateCheckboxButtons()
        invalidateTextLayout()
        setNeedsLayout()
    }

    private func applyAttributes(to lineIndex: Int) {
        guard lines.indices.contains(lineIndex),
              lines[lineIndex].range.location + lines[lineIndex].range.length <= textStorage.length else {
            return
        }
        textStorage.setAttributes(baseAttributes(), range: lines[lineIndex].range)
        applyAttributes(to: textStorage, line: lines[lineIndex])
    }

    private func applyAttributes(to attributedText: NSMutableAttributedString, lines: [StyleLine]) {
        for line in lines {
            applyAttributes(to: attributedText, line: line)
        }
    }

    private func applyAttributes(to attributedText: NSMutableAttributedString, line: StyleLine) {
        switch line.kind {
        case let .section(section):
            attributedText.addAttributes([
                .font: Self.sectionFont,
                .foregroundColor: UIColor.label,
            ], range: line.range)
            if let subtitleRange = sectionSubtitleRange(in: line, section: section) {
                attributedText.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: subtitleRange)
            }
        case let .property(property, _):
            guard let declarationRange = line.declarationRange else {
                return
            }
            var declarationAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: property.status == .disabled ? UIColor.secondaryLabel : UIColor.label,
                .paragraphStyle: Self.propertyParagraphStyle,
            ]
            if property.isOverridden {
                declarationAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            attributedText.addAttributes(declarationAttributes, range: declarationRange)
        case .closing:
            attributedText.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: line.range)
        case .blank:
            break
        }
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: Self.paragraphStyle,
        ]
    }

    private func updateCheckboxButtons() {
        for line in lines {
            guard let property = line.property,
                  let identity = line.propertyIdentity else {
                continue
            }
            updateCheckboxButton(for: property, identity: identity)
        }
        layoutCheckboxButtons()
    }

    private func updateCheckboxButton(for property: CSSProperty, identity: PropertyIdentity) {
        let checkboxControl = checkboxControlByIdentity[identity] ?? makeCheckboxControl(for: identity)
        checkboxControl.sideLength = Self.checkboxSideLength
        checkboxControl.isChecked = property.isEnabled
        checkboxControl.isEnabled = canToggle(property)
        checkboxControl.tintColor = checkboxControl.isEnabled ? .label : .secondaryLabel
        checkboxControl.accessibilityLabel = "\(webInspectorLocalized("dom.element.styles.toggle_property", default: "Toggle")) \(property.name)"
        checkboxControl.accessibilityValue = property.isEnabled
            ? webInspectorLocalized("enabled", default: "Enabled")
            : webInspectorLocalized("disabled", default: "Disabled")
    }

    private func makeCheckboxControl(for identity: PropertyIdentity) -> DOMElementStyleCheckboxControl {
        let checkboxControl = DOMElementStyleCheckboxControl(frame: .zero)
        checkboxControl.sideLength = Self.checkboxSideLength
        checkboxControl.addTarget(self, action: #selector(checkboxControlValueChanged(_:)), for: .valueChanged)
        textContentView.addSubview(checkboxControl)
        checkboxControlByIdentity[identity] = checkboxControl
        identityByCheckboxControlID[ObjectIdentifier(checkboxControl)] = identity
        return checkboxControl
    }

    private func removeCheckboxControls() {
        for checkboxControl in checkboxControlByIdentity.values {
            checkboxControl.removeFromSuperview()
        }
        checkboxControlByIdentity.removeAll(keepingCapacity: true)
        identityByCheckboxControlID.removeAll(keepingCapacity: true)
    }

    private func layoutCheckboxButtons() {
        for (identity, checkboxControl) in checkboxControlByIdentity {
            guard let lineIndex = propertyLineIndexByIdentity[identity],
                  lines.indices.contains(lineIndex),
                  let rowRect = contentRowRects(for: lines[lineIndex]).first else {
                checkboxControl.isHidden = true
                continue
            }
            checkboxControl.isHidden = false
            checkboxControl.frame = CGRect(
                x: 0,
                y: rowRect.minY,
                width: Self.checkboxColumnWidth,
                height: rowRect.height
            )
            textContentView.bringSubviewToFront(checkboxControl)
        }
    }

    private func checkboxHitRect(at contentPoint: CGPoint) -> Bool {
        checkboxControlByIdentity.values.contains { checkboxControl in
            !checkboxControl.isHidden && checkboxControl.frame.insetBy(dx: -6, dy: -6).contains(contentPoint)
        }
    }

    @objc private func checkboxControlValueChanged(_ sender: DOMElementStyleCheckboxControl) {
        guard let identity = identityByCheckboxControlID[ObjectIdentifier(sender)] else {
            return
        }
        requestToggle(identity)
    }

    private func requestToggle(_ identity: PropertyIdentity) {
        guard let property = propertyByIdentity[identity],
              canToggle(property),
              let propertyID = identity.propertyID else {
            return
        }
        _ = toggleAction?(propertyID, !property.isEnabled)
    }

    private func canToggle(_ property: CSSProperty) -> Bool {
        property.isEditable && property.id != nil && toggleAction != nil
    }

    private func declarationDisplayText(for property: CSSProperty) -> String {
        let declaration: String
        if property.status == .disabled {
            declaration = property.text ?? "/* \(declarationSourceText(for: property)) */"
        } else {
            declaration = property.text ?? declarationSourceText(for: property)
        }
        return normalizedSingleLineDeclaration(declaration)
    }

    private func sectionHeaderText(for section: CSSStyleSection) -> String {
        guard let subtitle = section.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else {
            return "\(section.title) {"
        }
        return "\(section.title) { /* \(normalizedSingleLineDeclaration(subtitle)) */"
    }

    private func sectionSubtitleRange(in line: StyleLine, section: CSSStyleSection) -> NSRange? {
        guard let subtitle = section.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else {
            return nil
        }
        let comment = "/* \(normalizedSingleLineDeclaration(subtitle)) */"
        let lineText = line.text as NSString
        let range = lineText.range(of: comment)
        guard range.location != NSNotFound else {
            return nil
        }
        return NSRange(location: line.range.location + range.location, length: range.length)
    }

    private func normalizedSingleLineDeclaration(_ declaration: String) -> String {
        declaration
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func declarationSourceText(for property: CSSProperty) -> String {
        var declaration = "\(property.name): \(property.value)"
        if !property.priority.isEmpty {
            declaration += " !\(property.priority)"
        }
        return declaration + ";"
    }

    private func propertyIdentity(for property: CSSProperty, in sectionID: CSSStyleSectionIdentifier) -> PropertyIdentity {
        if let id = property.id {
            return .identified(sectionID: sectionID, propertyID: id)
        }
        return .object(sectionID: sectionID, objectID: ObjectIdentifier(property))
    }

    private func membership(for nodeStyles: CSSNodeStyles) -> StyleMembership {
        StyleMembership(
            sections: nodeStyles.sections.compactMap { section in
                guard !section.style.cssProperties.isEmpty else {
                    return nil
                }
                return SectionMembership(
                    id: section.id,
                    properties: section.style.cssProperties.map { propertyIdentity(for: $0, in: section.id) }
                )
            }
        )
    }

    private func sectionLineTextNeedsUpdate(_ section: CSSStyleSection) -> Bool {
        let expectedText = sectionHeaderText(for: section)
        return lines.contains { line in
            if case let .section(existingSection) = line.kind, existingSection.id == section.id {
                return line.text != expectedText
            }
            return false
        }
    }

    private func updateMeasuredTextWidth() {
        measuredTextWidth = lines.reduce(CGFloat.zero) { partialResult, line in
            max(partialResult, measuredWidth(for: line))
        }
    }

    private func measuredWidth(for line: StyleLine) -> CGFloat {
        let font: UIFont
        let leadingWidth: CGFloat
        switch line.kind {
        case .section:
            font = Self.sectionFont
            leadingWidth = 0
        case .property:
            font = Self.font
            leadingWidth = Self.checkboxColumnWidth
        case .closing, .blank:
            font = Self.font
            leadingWidth = 0
        }
        return leadingWidth + ceil((line.text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func updateTextLayoutGeometry() {
        let visibleHeight = max(0, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom)
        let visibleWidth = max(0, bounds.width - adjustedContentInset.left - adjustedContentInset.right)
        let textHeight = CGFloat(max(lines.count, 1)) * Self.rowHeight
        let textWidth = max(visibleWidth - Self.textInsets.left - Self.textInsets.right, ceil(measuredTextWidth))
        let contentSize = CGSize(
            width: max(visibleWidth, textWidth + Self.textInsets.left + Self.textInsets.right),
            height: max(visibleHeight, textHeight + Self.textInsets.top + Self.textInsets.bottom)
        )
        if !self.contentSize.wiIsNearlyEqual(to: contentSize) {
            self.contentSize = contentSize
        }

        let textFrame = CGRect(
            x: Self.textInsets.left,
            y: Self.textInsets.top,
            width: max(textWidth, 1),
            height: max(textHeight, Self.rowHeight)
        )
        if !textContentView.frame.wiIsNearlyEqual(to: textFrame) {
            textContentView.frame = textFrame
        }

        let containerSize = CGSize(width: textFrame.width, height: CGFloat.greatestFiniteMagnitude)
        if !textContainer.size.wiIsNearlyEqual(to: containerSize) {
            textContainer.size = containerSize
        }
    }

    private func visibleTextRect(horizontalPadding: CGFloat = 64) -> CGRect {
        let rawRect = CGRect(
            x: bounds.minX - textContentView.frame.minX,
            y: bounds.minY - textContentView.frame.minY,
            width: bounds.width,
            height: bounds.height
        )
        let paddedRect = rawRect.insetBy(dx: -horizontalPadding, dy: 0)
        let contentBounds = CGRect(origin: .zero, size: textContentView.bounds.size)
        let intersection = paddedRect.intersection(contentBounds)
        if !intersection.isNull, intersection.width > 0 {
            return intersection
        }
        return CGRect(
            x: max(0, min(paddedRect.minX, contentBounds.maxX)),
            y: max(0, min(paddedRect.minY, contentBounds.maxY)),
            width: min(max(paddedRect.width, 1), max(contentBounds.width, 1)),
            height: min(max(paddedRect.height, 1), max(contentBounds.height, 1))
        )
    }

    private func resetTextFragmentViews() {
        for case let fragmentView as DOMElementStylesTextLayoutFragmentView in textContentView.subviews {
            fragmentView.removeFromSuperview()
        }
        fragmentViewMap.removeAllObjects()
        lastUsedFragmentViews.removeAll(keepingCapacity: true)
    }

    private func invalidateTextLayout(including range: NSRange? = nil) {
        layoutManager.invalidateLayout(for: textContentStorage.documentRange)
        if let range {
            setNeedsDisplayForTextRange(range)
        } else {
            setNeedsDisplayForVisibleTextFragments()
        }
    }

    private func setNeedsDisplayForTextRange(_ range: NSRange) {
        let rects = textSegmentRects(for: range, type: .standard)
        guard !rects.isEmpty else {
            setNeedsDisplayForVisibleTextFragments()
            return
        }
        var invalidatedRect = CGRect.null
        for rect in rects {
            invalidatedRect = invalidatedRect.union(rect)
        }
        for case let fragmentView as DOMElementStylesTextLayoutFragmentView in textContentView.subviews {
            guard fragmentView.frame.intersects(invalidatedRect) else {
                continue
            }
            fragmentView.setNeedsDisplay(invalidatedRect.offsetBy(dx: -fragmentView.frame.minX, dy: -fragmentView.frame.minY))
        }
    }

    private func setNeedsDisplayForVisibleTextFragments() {
        for case let fragmentView as DOMElementStylesTextLayoutFragmentView in textContentView.subviews {
            fragmentView.setNeedsDisplay()
        }
    }

    private func textSegmentRects(
        for range: NSRange,
        type: NSTextLayoutManager.SegmentType,
        options: NSTextLayoutManager.SegmentOptions = [.rangeNotRequired]
    ) -> [CGRect] {
        guard let textRange = textRange(for: range) else {
            return []
        }
        layoutManager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: type,
            options: options
        ) { _, rect, _, _ in
            rects.append(rect)
            return true
        }
        return rects
    }

    private func contentRowRects(for line: StyleLine) -> [CGRect] {
        textSegmentRects(for: line.range, type: .highlight).map { textRect in
            CGRect(
                x: 0,
                y: textRect.minY,
                width: max(textContentView.bounds.width, contentSize.width - Self.textInsets.left - Self.textInsets.right),
                height: textRect.height
            )
        }
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        let clampedRange = clampedTextRange(range)
        guard let start = textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: clampedRange.location
        ),
        let end = textContentStorage.location(start, offsetBy: clampedRange.length)
        else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }

    private func row(atContentPoint point: CGPoint) -> StyleLine? {
        guard point.y >= 0,
              let textRange = lineFragmentTextRange(at: point),
              let textOffset = textOffset(for: textRange.location)
        else {
            return nil
        }
        return row(containingTextOffset: textOffset)
    }

    private func lineFragmentTextRange(at location: CGPoint) -> NSTextRange? {
        layoutManager.ensureLayout(for: visibleTextRect(horizontalPadding: 0))
        return layoutManager.lineFragmentRange(
            for: location,
            inContainerAt: textContentStorage.documentRange.location
        )
    }

    private func textOffset(for location: any NSTextLocation) -> Int? {
        let offset = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: location
        )
        guard offset != NSNotFound else {
            return nil
        }
        return clampedTextOffset(offset)
    }

    private func row(containingTextOffset offset: Int) -> StyleLine? {
        let offset = clampedTextOffset(offset)
        return lines.first { line in
            offset >= line.range.location && offset <= NSMaxRange(line.range)
        }
    }

    private func firstIdentity(matching propertyID: CSSPropertyIdentifier) -> PropertyIdentity? {
        lines.compactMap(\.propertyIdentity).first { identity in
            identity.propertyID == propertyID
        }
    }

    private func firstLineIndex(containing text: String) -> Int? {
        lines.firstIndex { line in
            line.text.contains(text)
        }
    }
}

extension DOMElementStylesTextView {
    package var hasText: Bool {
        !renderedText.isEmpty
    }

    package func insertText(_ text: String) {}

    package func deleteBackward() {}

    package var selectedTextRange: UITextRange? {
        get { DOMElementStylesTextRange(range: selectedTextNSRange) }
        set { setSelectedTextRange(newValue) }
    }

    package var markedTextRange: UITextRange? {
        markedTextNSRange.map(DOMElementStylesTextRange.init(range:))
    }

    package var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { markedTextStyleStorage }
        set { markedTextStyleStorage = newValue }
    }

    package var beginningOfDocument: UITextPosition {
        DOMElementStylesTextPosition(offset: 0)
    }

    package var endOfDocument: UITextPosition {
        DOMElementStylesTextPosition(offset: renderedTextUTF16Length)
    }

    package var tokenizer: UITextInputTokenizer {
        textInputTokenizer
    }

    package var textInputView: UIView {
        self
    }

    package func text(in range: UITextRange) -> String? {
        let range = clampedTextRange(nsRange(from: range))
        guard range.length > 0 else {
            return ""
        }
        return (renderedText as NSString).substring(with: range)
    }

    package func replace(_ range: UITextRange, withText text: String) {}

    package func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        markedTextNSRange = markedText.map { _ in selectedTextNSRange }
    }

    package func unmarkText() {
        markedTextNSRange = nil
    }

    package func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let startOffset = offset(from: fromPosition)
        let endOffset = offset(from: toPosition)
        let lower = min(startOffset, endOffset)
        let upper = max(startOffset, endOffset)
        return DOMElementStylesTextRange(range: clampedTextRange(NSRange(location: lower, length: upper - lower)))
    }

    package func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        DOMElementStylesTextPosition(offset: clampedTextOffset(self.offset(from: position) + offset))
    }

    package func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        let signedOffset = switch direction {
        case .left, .up:
            -offset
        case .right, .down:
            offset
        @unknown default:
            offset
        }
        return self.position(from: position, offset: signedOffset)
    }

    package func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = offset(from: position)
        let rhs = offset(from: other)
        if lhs == rhs {
            return .orderedSame
        }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    package func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        offset(from: toPosition) - offset(from: from)
    }

    package func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        let range = nsRange(from: range)
        let offset = switch direction {
        case .left, .up:
            range.location
        case .right, .down:
            NSMaxRange(range)
        @unknown default:
            range.location
        }
        return DOMElementStylesTextPosition(offset: clampedTextOffset(offset))
    }

    package func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let offset = offset(from: position)
        let range: NSRange
        switch direction {
        case .left, .up:
            range = NSRange(location: max(0, offset - 1), length: min(1, offset))
        case .right, .down:
            range = NSRange(location: offset, length: offset < renderedTextUTF16Length ? 1 : 0)
        @unknown default:
            range = NSRange(location: offset, length: 0)
        }
        return DOMElementStylesTextRange(range: clampedTextRange(range))
    }

    package func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    package func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    package func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .zero
    }

    package func caretRect(for position: UITextPosition) -> CGRect {
        let offset = offset(from: position)
        let rects = textSegmentRects(
            for: NSRange(location: offset, length: 0),
            type: .standard,
            options: [.rangeNotRequired, .upstreamAffinity]
        )
        guard let segmentRect = rects.first else {
            return .zero
        }
        let localRect = CGRect(
            x: segmentRect.minX,
            y: segmentRect.minY,
            width: 2,
            height: segmentRect.height
        )
        return textContentView.convert(localRect, to: self)
    }

    package func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let range = clampedTextRange(nsRange(from: range))
        guard range.length > 0,
              let textRange = textRange(for: range)
        else {
            return []
        }

        var rects: [UITextSelectionRect] = []
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: [.rangeNotRequired]
        ) { [weak self] _, rect, _, _ in
            guard let self else {
                return false
            }
            rects.append(
                DOMElementStylesTextSelectionRect(
                    rect: self.textContentView.convert(rect, to: self),
                    containsStart: rects.isEmpty,
                    containsEnd: false
                )
            )
            return true
        }
        if let lastRect = rects.last as? DOMElementStylesTextSelectionRect {
            lastRect.containsSelectionEnd = true
        }
        return rects
    }

    package func closestPosition(to point: CGPoint) -> UITextPosition? {
        DOMElementStylesTextPosition(offset: textOffset(at: point))
    }

    package func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        let range = clampedTextRange(nsRange(from: range))
        return DOMElementStylesTextPosition(offset: min(max(textOffset(at: point), range.location), NSMaxRange(range)))
    }

    package func characterRange(at point: CGPoint) -> UITextRange? {
        let offset = textOffset(at: point)
        return DOMElementStylesTextRange(
            range: clampedTextRange(
                NSRange(location: offset, length: offset < renderedTextUTF16Length ? 1 : 0)
            )
        )
    }

    private var renderedTextUTF16Length: Int {
        (renderedText as NSString).length
    }

    private func setSelectedTextRange(_ range: UITextRange?) {
        let nextRange = range.map { clampedTextRange(nsRange(from: $0)) } ?? NSRange(location: 0, length: 0)
        guard selectedTextNSRange != nextRange else {
            return
        }
        inputDelegate?.selectionWillChange(self)
        selectedTextNSRange = nextRange
        inputDelegate?.selectionDidChange(self)
    }

    private func clampTextSelectionAfterTextChange() {
        selectedTextNSRange = clampedTextRange(selectedTextNSRange)
        if let markedTextNSRange {
            self.markedTextNSRange = clampedTextRange(markedTextNSRange)
        }
    }

    private func nsRange(from range: UITextRange) -> NSRange {
        guard let range = range as? DOMElementStylesTextRange else {
            return NSRange(location: 0, length: 0)
        }
        return range.range
    }

    private func offset(from position: UITextPosition) -> Int {
        guard let position = position as? DOMElementStylesTextPosition else {
            return 0
        }
        return clampedTextOffset(position.offset)
    }

    private func clampedTextRange(_ range: NSRange) -> NSRange {
        let length = renderedTextUTF16Length
        let lower = min(max(0, range.location), length)
        let upper = min(max(lower, range.location + range.length), length)
        return NSRange(location: lower, length: upper - lower)
    }

    private func clampedTextOffset(_ offset: Int) -> Int {
        min(max(0, offset), renderedTextUTF16Length)
    }

    private func textOffset(at point: CGPoint) -> Int {
        let contentPoint = convert(point, to: textContentView)
        guard let row = row(atContentPoint: contentPoint) else {
            if contentPoint.y < 0 {
                return 0
            }
            return renderedTextUTF16Length
        }

        let leadingWidth: CGFloat
        if case .property = row.kind {
            leadingWidth = Self.checkboxColumnWidth
        } else {
            leadingWidth = 0
        }
        let column = min(
            max(0, Int(round((contentPoint.x - leadingWidth) / Self.characterWidth))),
            row.range.length
        )
        return clampedTextOffset(row.range.location + column)
    }
}

#if DEBUG
extension DOMElementStylesTextView {
    package var renderedTextForTesting: String {
        renderedText
    }

    package var attributedTextForTesting: NSAttributedString {
        NSAttributedString(attributedString: textStorage)
    }

    package var isTextSelectableForTesting: Bool {
        true
    }

    package var isTextEditableForTesting: Bool {
        false
    }

    package var isHorizontallyScrollableForTesting: Bool {
        alwaysBounceHorizontal
    }

    package var showsHorizontalScrollIndicatorForTesting: Bool {
        showsHorizontalScrollIndicator
    }

    package var rebuildTextStorageCallCountForTesting: Int {
        rebuildTextStorageCallCount
    }

    package var incrementalPropertyUpdateCallCountForTesting: Int {
        incrementalPropertyUpdateCallCount
    }

    package func resetRenderCountersForTesting() {
        rebuildTextStorageCallCount = 0
        incrementalPropertyUpdateCallCount = 0
    }

    package func isCheckboxCheckedForTesting(propertyID: CSSPropertyIdentifier) -> Bool? {
        checkboxControlForTesting(propertyID: propertyID)?.isChecked
            ?? propertyForTesting(propertyID: propertyID)?.isEnabled
    }

    package func isCheckboxEnabledForTesting(propertyID: CSSPropertyIdentifier) -> Bool? {
        checkboxControlForTesting(propertyID: propertyID)?.isEnabled
            ?? propertyForTesting(propertyID: propertyID).map(canToggle)
    }

    package func isCheckboxBackedByControlForTesting(propertyID: CSSPropertyIdentifier) -> Bool {
        checkboxControlForTesting(propertyID: propertyID) != nil
    }

    package func checkboxControlSizeForTesting(propertyID: CSSPropertyIdentifier) -> CGSize? {
        checkboxControlForTesting(propertyID: propertyID)?.bounds.size
    }

    package func checkboxControlFrameForTesting(propertyID: CSSPropertyIdentifier) -> CGRect? {
        checkboxControlForTesting(propertyID: propertyID)?.frame
    }

    package func contentRowFrameForTesting(propertyID: CSSPropertyIdentifier) -> CGRect? {
        guard let identity = firstIdentity(matching: propertyID),
              let lineIndex = propertyLineIndexByIdentity[identity],
              lines.indices.contains(lineIndex) else {
            return nil
        }
        return contentRowRects(for: lines[lineIndex]).first
    }

    package var rowHeightForTesting: CGFloat {
        Self.rowHeight
    }

    package func tapCheckboxForTesting(propertyID: CSSPropertyIdentifier) {
        guard let identity = firstIdentity(matching: propertyID) else {
            return
        }
        guard checkboxControlByIdentity[identity] != nil else {
            return
        }
        requestToggle(identity)
    }

    package func tapCheckboxForTesting(lineContaining text: String) {
        guard let lineIndex = firstLineIndex(containing: text),
              let identity = lines[lineIndex].propertyIdentity else {
            return
        }
        requestToggle(identity)
    }

    package func declarationRangeForTesting(propertyID: CSSPropertyIdentifier) -> NSRange? {
        guard let identity = firstIdentity(matching: propertyID),
              let lineIndex = propertyLineIndexByIdentity[identity],
              lines.indices.contains(lineIndex) else {
            return nil
        }
        return lines[lineIndex].declarationRange
    }

    package var contentSizeForTesting: CGSize {
        contentSize
    }

    private func checkboxControlForTesting(propertyID: CSSPropertyIdentifier) -> DOMElementStyleCheckboxControl? {
        guard let identity = firstIdentity(matching: propertyID) else {
            return nil
        }
        return checkboxControlByIdentity[identity]
    }

    private func propertyForTesting(propertyID: CSSPropertyIdentifier) -> CSSProperty? {
        guard let identity = firstIdentity(matching: propertyID) else {
            return nil
        }
        return propertyByIdentity[identity]
    }
}
#endif

private final class DOMElementStylesTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

private final class DOMElementStylesTextRange: UITextRange {
    let range: NSRange

    init(range: NSRange) {
        self.range = range
        super.init()
    }

    override var start: UITextPosition {
        DOMElementStylesTextPosition(offset: range.location)
    }

    override var end: UITextPosition {
        DOMElementStylesTextPosition(offset: NSMaxRange(range))
    }

    override var isEmpty: Bool {
        range.length == 0
    }
}

private final class DOMElementStylesTextSelectionRect: UITextSelectionRect {
    private let storageRect: CGRect
    private let containsSelectionStart: Bool
    var containsSelectionEnd: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        self.storageRect = rect
        self.containsSelectionStart = containsStart
        self.containsSelectionEnd = containsEnd
        super.init()
    }

    override var rect: CGRect {
        storageRect
    }

    override var writingDirection: NSWritingDirection {
        .leftToRight
    }

    override var containsStart: Bool {
        containsSelectionStart
    }

    override var containsEnd: Bool {
        containsSelectionEnd
    }

    override var isVertical: Bool {
        false
    }
}

private final class DOMElementStylesTextContentView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class DOMElementStyleCheckboxControl: UIControl {
    var sideLength: CGFloat = 14 {
        didSet {
            guard !oldValue.wiIsNearlyEqual(to: sideLength) else {
                return
            }
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    var isChecked = true {
        didSet {
            guard oldValue != isChecked else {
                return
            }
            updateAccessibilityTraits()
            setNeedsDisplay()
        }
    }

    override var isEnabled: Bool {
        didSet {
            updateAccessibilityTraits()
            setNeedsDisplay()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            setNeedsDisplay()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: sideLength, height: sideLength)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = true
        updateAccessibilityTraits()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        let boxRect = CGRect(
            x: (bounds.width - sideLength) / 2,
            y: (bounds.height - sideLength) / 2,
            width: sideLength,
            height: sideLength
        ).insetBy(dx: 1, dy: 1)

        let alpha: CGFloat
        if !isEnabled {
            alpha = 0.45
        } else if isHighlighted {
            alpha = 0.7
        } else {
            alpha = 1
        }

        let color = (tintColor ?? .label).withAlphaComponent(alpha)
        let boxPath = UIBezierPath(roundedRect: boxRect, cornerRadius: 2)
        if isChecked {
            color.withAlphaComponent(0.12).setFill()
            boxPath.fill()
        }
        color.setStroke()
        boxPath.lineWidth = 1.5
        boxPath.stroke()

        guard isChecked else {
            return
        }

        let checkPath = UIBezierPath()
        checkPath.move(to: CGPoint(x: boxRect.minX + boxRect.width * 0.24, y: boxRect.midY))
        checkPath.addLine(to: CGPoint(x: boxRect.minX + boxRect.width * 0.43, y: boxRect.maxY - boxRect.height * 0.25))
        checkPath.addLine(to: CGPoint(x: boxRect.maxX - boxRect.width * 0.2, y: boxRect.minY + boxRect.height * 0.25))
        checkPath.lineWidth = 1.7
        checkPath.lineCapStyle = .round
        checkPath.lineJoinStyle = .round
        color.setStroke()
        checkPath.stroke()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else {
            return false
        }
        isHighlighted = true
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isHighlighted = bounds.insetBy(dx: -8, dy: -8).contains(touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        defer {
            isHighlighted = false
        }
        guard isEnabled,
              let touch,
              bounds.insetBy(dx: -8, dy: -8).contains(touch.location(in: self)) else {
            return
        }
        sendActions(for: .valueChanged)
    }

    override func cancelTracking(with event: UIEvent?) {
        isHighlighted = false
    }

    private func updateAccessibilityTraits() {
        var traits: UIAccessibilityTraits = [.button]
        if isChecked {
            traits.insert(.selected)
        }
        accessibilityTraits = traits
    }
}

private final class DOMElementStylesTextLayoutFragmentView: UIView {
    let layoutFragment: NSTextLayoutFragment
    var layoutFragmentDrawPoint = CGPoint.zero

    init(layoutFragment: NSTextLayoutFragment, frame: CGRect) {
        self.layoutFragment = layoutFragment
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        layoutFragment.draw(at: layoutFragmentDrawPoint, in: context)
    }
}

private extension CGRect {
    func wiIsNearlyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        origin.x.wiIsNearlyEqual(to: other.origin.x, tolerance: tolerance)
            && origin.y.wiIsNearlyEqual(to: other.origin.y, tolerance: tolerance)
            && size.wiIsNearlyEqual(to: other.size, tolerance: tolerance)
    }
}

private extension CGSize {
    func wiIsNearlyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        width.wiIsNearlyEqual(to: other.width, tolerance: tolerance)
            && height.wiIsNearlyEqual(to: other.height, tolerance: tolerance)
    }
}

private extension CGFloat {
    func wiIsNearlyEqual(to other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(self - other) <= tolerance
    }
}
#endif
