#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class DOMTreeTextView: UIScrollView, @preconcurrency NSTextViewportLayoutControllerDelegate, UIContextMenuInteractionDelegate {
    private static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let lineSpacing: CGFloat = 2
    private static let textInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 16)
    private static let indentSpacesPerDepth = 2
    private static let disclosureSlotSpaces = 2
    fileprivate static let iconSide: CGFloat = 9
    private static var characterWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }
    private static var disclosureSlotWidth: CGFloat {
        CGFloat(disclosureSlotSpaces) * characterWidth
    }
    private static var paragraphStyle: NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.minimumLineHeight = ceil(font.lineHeight + lineSpacing)
        paragraphStyle.maximumLineHeight = ceil(font.lineHeight + lineSpacing)
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        return paragraphStyle
    }

    private let dom: WIDOMRuntime
    private let observationScope = ObservationScope()
    private let textContentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer()
    private let textContentView = DOMTreeTextContentView()
    private let fragmentViewMap = NSMapTable<NSTextLayoutFragment, DOMTreeTextLayoutFragmentView>.weakToWeakObjects()
    private var lastUsedFragmentViews: Set<DOMTreeTextLayoutFragmentView> = []
    private lazy var findCoordinator = DOMTreeFindCoordinator(textView: self)

    private var rows: [DOMTreeLine] = []
    private var renderedText = ""
    private var openState: [DOMNodeModel.ID: Bool] = [:]
    private var hoveredNodeID: DOMNodeModel.ID?
    private var requestedChildNodeIDs: Set<DOMNodeModel.ID> = []
    private var findFoundRanges: [NSRange] = []
    private var findHighlightedRanges: [NSRange] = []
    private var measuredTextWidth: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var rowIndexByNodeID: [DOMNodeModel.ID: Int] = [:]
    private var lastObservedSelectedNodeID: DOMNodeModel.ID?
    private var pendingRevealSelectedNodeID: DOMNodeModel.ID?

    private var textStorage: NSTextStorage {
        guard let storage = textContentStorage.textStorage else {
            fatalError("DOMTreeTextView requires NSTextContentStorage-backed NSTextStorage")
        }
        return storage
    }

    var renderedTextForFind: String {
        renderedText
    }

    private var rowHeight: CGFloat {
        ceil(Self.font.lineHeight + Self.lineSpacing)
    }

    init(dom: WIDOMRuntime) {
        self.dom = dom
        super.init(frame: .zero)
        configureTextSystem()
        configureInteractions()
        startObservingDocument()
        reloadTree()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                input: "f",
                modifierFlags: .command,
                action: #selector(showFindNavigator),
                discoverabilityTitle: wiLocalized("Find")
            )
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard lastBoundsSize != bounds.size || textContentView.frame.isEmpty else {
            layoutManager.textViewportLayoutController.layoutViewport()
            return
        }
        lastBoundsSize = bounds.size
        updateTextLayoutGeometry()
        layoutManager.textViewportLayoutController.layoutViewport()
        revealPendingSelectedNodeIfPossible()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else {
            return
        }

        reapplyTextAttributes()
        updateFindHighlightFragmentViews()
    }

    func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let scrollInsets = adjustedContentInset
        return CGRect(
            x: bounds.origin.x - scrollInsets.left - Self.textInsets.left,
            y: bounds.origin.y - scrollInsets.top - Self.textInsets.top,
            width: bounds.width + scrollInsets.left + scrollInsets.right + Self.textInsets.left + Self.textInsets.right,
            height: bounds.height + scrollInsets.top + scrollInsets.bottom + Self.textInsets.top + Self.textInsets.bottom
        )
    }

    func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        lastUsedFragmentViews = Set(
            fragmentViewMap.objectEnumerator()?.allObjects as? [DOMTreeTextLayoutFragmentView] ?? []
        )
    }

    func textViewportLayoutController(
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
        let fragmentView: DOMTreeTextLayoutFragmentView
        if let cachedView = fragmentViewMap.object(forKey: textLayoutFragment) {
            fragmentView = cachedView
            lastUsedFragmentViews.remove(cachedView)
        } else {
            fragmentView = DOMTreeTextLayoutFragmentView(layoutFragment: textLayoutFragment, frame: surfaceFrame)
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }

        fragmentView.layoutFragmentDrawPoint = CGPoint(
            x: layoutFrame.minX - surfaceFrame.minX,
            y: layoutFrame.minY - surfaceFrame.minY
        )
        configureHighlights(
            for: fragmentView,
            layoutFragmentFrame: layoutFrame,
            surfaceFrame: surfaceFrame
        )

        if !fragmentView.frame.wiIsNearlyEqual(to: surfaceFrame) {
            fragmentView.frame = surfaceFrame
            fragmentView.setNeedsDisplay()
        }
        if fragmentView.superview !== textContentView {
            textContentView.addSubview(fragmentView)
        }
    }

    func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
        }
        lastUsedFragmentViews.removeAll()
        updateTextLayoutGeometry()
    }

    @objc private func showFindNavigator() {
        becomeFirstResponder()
        findCoordinator.findInteraction.presentFindNavigator(showingReplace: false)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let row = row(at: recognizer.location(in: textContentView))
        else {
            return
        }

        let location = recognizer.location(in: textContentView)
        if row.hasDisclosure,
           location.x >= row.disclosureRect.minX,
           location.x <= row.disclosureRect.maxX {
            toggle(row: row)
        } else {
            select(row.node)
        }
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            guard let row = row(at: recognizer.location(in: textContentView)) else {
                clearHoveredRow()
                Task { @MainActor [dom] in await dom.hideNodeHighlight() }
                return
            }
            if hoveredNodeID != row.node.id {
                hoveredNodeID = row.node.id
                updateFindHighlightFragmentViews()
            }
            Task { @MainActor [dom, node = row.node] in
                await dom.highlightNode(node, reveal: false)
            }
        case .ended, .cancelled, .failed:
            clearHoveredRow()
            Task { @MainActor [dom] in await dom.hideNodeHighlight() }
        default:
            break
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let row = row(at: convert(location, to: textContentView)) else {
            return nil
        }

        select(row.node)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak node = row.node] _ in
            guard let self, let node else {
                return UIMenu(children: [])
            }
            return self.makeContextMenu(for: node)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let textRange = textRange(for: range) else {
            return
        }

        layoutManager.ensureLayout(for: textRange)
        var targetRect: CGRect?
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: [.rangeNotRequired]
        ) { _, rect, _, _ in
            targetRect = targetRect.map { $0.union(rect) } ?? rect
            return true
        }

        guard let targetRect else {
            return
        }
        let visibleRect = targetRect
            .offsetBy(dx: Self.textInsets.left, dy: Self.textInsets.top)
            .insetBy(dx: -24, dy: -12)
        scrollRectToVisible(visibleRect, animated: true)
    }

    func decorateFindTextRange(_ range: NSRange, style: UITextSearchFoundTextStyle) {
        let clampedRange = clampedTextRange(range)
        guard clampedRange.length > 0 else {
            return
        }

        findFoundRanges.removeAll { $0 == clampedRange }
        findHighlightedRanges.removeAll { $0 == clampedRange }
        switch style {
        case .normal:
            break
        case .found:
            findFoundRanges.append(clampedRange)
        case .highlighted:
            findHighlightedRanges.append(clampedRange)
        @unknown default:
            findFoundRanges.append(clampedRange)
        }
        updateFindHighlightFragmentViews()
    }

    func clearFindDecorations() {
        guard !findFoundRanges.isEmpty || !findHighlightedRanges.isEmpty else {
            return
        }
        findFoundRanges.removeAll()
        findHighlightedRanges.removeAll()
        updateFindHighlightFragmentViews()
    }

    func clampedTextRange(_ range: NSRange) -> NSRange {
        let length = (renderedText as NSString).length
        let lower = min(max(0, range.location), length)
        let upper = min(max(lower, range.location + range.length), length)
        return NSRange(location: lower, length: upper - lower)
    }

    private func configureTextSystem() {
        backgroundColor = .clear
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true
        showsHorizontalScrollIndicator = true
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
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapRecognizer)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
        addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(findCoordinator.findInteraction)
    }

    private func startObservingDocument() {
        dom.document.observe([\.rootNode, \.errorMessage, \.projectionRevision]) { [weak self] in
            self?.reloadTree()
        }
        .store(in: observationScope)

        dom.document.observe(\.selectedNode) { [weak self] _ in
            self?.reloadTree()
        }
        .store(in: observationScope)
    }

    private func reloadTree() {
        prepareSelectionForRendering()
        let buildResult = buildRenderedRows()
        rows = buildResult.rows
        rowIndexByNodeID = Dictionary(uniqueKeysWithValues: rows.map { ($0.node.id, $0.rowIndex) })
        renderedText = buildResult.text
        measuredTextWidth = measureTextWidth(renderedText)
        requestedChildNodeIDs = requestedChildNodeIDs.filter { nodeID in
            dom.document.node(id: nodeID) != nil
        }

        let attributedText = NSMutableAttributedString(
            string: renderedText.isEmpty ? "\n" : renderedText,
            attributes: baseTextAttributes()
        )
        applyRowAttributes(to: attributedText)
        textStorage.setAttributedString(attributedText)

        clearFindDecorations()
        findCoordinator.invalidateResultsAfterTextChange()
        updateTextLayoutGeometry()
        setNeedsLayout()
        revealPendingSelectedNodeIfPossible()
    }

    private func prepareSelectionForRendering() {
        let selectedNode = dom.document.selectedNode
        let selectedNodeID = selectedNode?.id
        if selectedNodeID != lastObservedSelectedNodeID {
            lastObservedSelectedNodeID = selectedNodeID
            pendingRevealSelectedNodeID = selectedNodeID
        }

        guard let selectedNode else {
            pendingRevealSelectedNodeID = nil
            return
        }
        openAncestors(of: selectedNode)
    }

    private func openAncestors(of node: DOMNodeModel) {
        var current = node.parent
        while let ancestor = current {
            if ancestor.nodeType != .document {
                openState[ancestor.id] = true
            }
            current = ancestor.parent
        }
    }

    private func buildRenderedRows() -> (rows: [DOMTreeLine], text: String) {
        guard let rootNode = dom.document.rootNode else {
            return ([], "")
        }

        var nextRows: [DOMTreeLine] = []
        var lines: [String] = []
        var utf16Location = 0

        func append(_ node: DOMNodeModel, depth: Int) {
            let hasDisclosure = node.childCount > 0
            let isOpen = isNodeOpen(node, depth: depth)
            let markup = DOMTreeMarkupBuilder.markup(for: node, hasDisclosure: hasDisclosure, isOpen: isOpen)
            let prefix = renderedLinePrefix(depth: depth)
            let line = prefix + markup.text
            let prefixLength = (prefix as NSString).length
            let lineLength = (line as NSString).length
            let rowIndex = nextRows.count
            let textRange = NSRange(location: utf16Location, length: lineLength)
            let markupRange = NSRange(location: prefixLength, length: (markup.text as NSString).length)
            let disclosureX = Self.disclosureX(depth: depth)
            let disclosureRect = CGRect(
                x: disclosureX,
                y: CGFloat(rowIndex) * rowHeight,
                width: Self.disclosureSlotWidth,
                height: rowHeight
            )
            let tokens = markup.tokens.map {
                DOMTreeToken(
                    kind: $0.kind,
                    range: NSRange(location: prefixLength + $0.range.location, length: $0.range.length)
                )
            }

            nextRows.append(
                DOMTreeLine(
                    node: node,
                    depth: depth,
                    rowIndex: rowIndex,
                    text: line,
                    textRange: textRange,
                    markupRange: markupRange,
                    tokens: tokens,
                    hasDisclosure: hasDisclosure,
                    isOpen: isOpen,
                    disclosureRect: disclosureRect
                )
            )
            lines.append(line)
            utf16Location += lineLength + 1

            guard hasDisclosure, isOpen else {
                return
            }
            requestChildrenIfNeeded(for: node)
            for child in node.children {
                append(child, depth: depth + 1)
            }
        }

        let displayRoots = rootNode.nodeType == .document ? rootNode.children : [rootNode]
        for node in displayRoots {
            append(node, depth: 0)
        }

        return (nextRows, lines.joined(separator: "\n"))
    }

    private func isNodeOpen(_ node: DOMNodeModel, depth: Int) -> Bool {
        if let explicitState = openState[node.id] {
            return explicitState
        }
        if nodeName(for: node).lowercased() == "head" {
            return false
        }
        let name = nodeName(for: node).lowercased()
        return name == "html" || name == "body"
    }

    private func renderedLinePrefix(depth: Int) -> String {
        String(repeating: " ", count: depth * Self.indentSpacesPerDepth + Self.disclosureSlotSpaces)
    }

    private static func disclosureX(depth: Int) -> CGFloat {
        CGFloat(depth * indentSpacesPerDepth) * characterWidth
    }

    private func nodeName(for node: DOMNodeModel) -> String {
        if !node.localName.isEmpty {
            return node.localName
        }
        if !node.nodeName.isEmpty {
            return node.nodeName
        }
        return node.preview
    }

    private func requestChildrenIfNeeded(for node: DOMNodeModel) {
        guard node.childCount > node.children.count,
              requestedChildNodeIDs.insert(node.id).inserted
        else {
            return
        }
        Task { @MainActor [dom, weak node] in
            guard let node else {
                return
            }
            await dom.requestChildNodes(for: node, depth: 3)
        }
    }

    private func toggle(row: DOMTreeLine) {
        openState[row.node.id] = !row.isOpen
        reloadTree()
    }

    private func select(_ node: DOMNodeModel) {
        Task { @MainActor [dom] in
            await dom.selectNode(node)
        }
    }

    private func row(at location: CGPoint) -> DOMTreeLine? {
        guard location.y >= 0 else {
            return nil
        }
        let index = Int(location.y / rowHeight)
        guard rows.indices.contains(index) else {
            return nil
        }
        return rows[index]
    }

    private func clearHoveredRow() {
        guard hoveredNodeID != nil else {
            return
        }
        hoveredNodeID = nil
        updateFindHighlightFragmentViews()
    }

    private func makeContextMenu(for node: DOMNodeModel) -> UIMenu {
        let copyHTML = UIAction(title: "Copy HTML") { [weak self, weak node] _ in
            guard let self, let node else {
                return
            }
            Task { @MainActor [dom] in
                guard let text = try? await dom.copyHTML(for: node), !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            }
        }

        let copySelectorPath = UIAction(title: "Copy Selector Path") { [weak self, weak node] _ in
            guard let self, let node else {
                return
            }
            Task { @MainActor [dom] in
                guard let text = try? await dom.copySelectorPath(for: node), !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            }
        }

        let copyXPath = UIAction(title: "Copy XPath") { [weak self, weak node] _ in
            guard let self, let node else {
                return
            }
            Task { @MainActor [dom] in
                guard let text = try? await dom.copyXPath(for: node), !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            }
        }

        let deleteNode = UIAction(
            title: "Delete Node",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self, weak node] _ in
            guard let self, let node else {
                return
            }
            Task { @MainActor [dom, undoManager] in
                try? await dom.deleteNode(node, undoManager: undoManager)
            }
        }

        return UIMenu(children: [copyHTML, copySelectorPath, copyXPath, deleteNode])
    }

    private func applyRowAttributes(to attributedText: NSMutableAttributedString) {
        for row in rows {
            applySyntaxAttributes(for: row, to: attributedText)
        }
    }

    private func baseTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: Self.font,
            .paragraphStyle: Self.paragraphStyle,
            .foregroundColor: DOMTreeHighlightTheme.webInspector.baseForeground.resolvedColor(with: traitCollection)
        ]
    }

    private func reapplyTextAttributes() {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else {
            return
        }
        textStorage.addAttributes(baseTextAttributes(), range: fullRange)
        applyRowAttributes(to: textStorage)
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            fragmentView.setNeedsDisplay()
        }
    }

    private func applySyntaxAttributes(for row: DOMTreeLine, to attributedText: NSMutableAttributedString) {
        attributedText.addAttribute(
            .foregroundColor,
            value: DOMTreeTokenKind.fallback.color(resolvedFor: traitCollection),
            range: row.textRange
        )
        for token in row.tokens {
            attributedText.addAttribute(
                .foregroundColor,
                value: token.kind.color(resolvedFor: traitCollection),
                range: NSRange(location: row.textRange.location + token.range.location, length: token.range.length)
            )
        }
    }

    private func updateTextLayoutGeometry() {
        let height = max(bounds.height - adjustedContentInset.top - adjustedContentInset.bottom, CGFloat(max(rows.count, 1)) * rowHeight)
        let width = max(
            bounds.width - adjustedContentInset.left - adjustedContentInset.right,
            ceil(measuredTextWidth + Self.textInsets.left + Self.textInsets.right)
        )
        let contentSize = CGSize(width: width, height: height + Self.textInsets.top + Self.textInsets.bottom)
        if !self.contentSize.wiIsNearlyEqual(to: contentSize) {
            self.contentSize = contentSize
        }

        let textFrame = CGRect(
            x: Self.textInsets.left,
            y: Self.textInsets.top,
            width: max(width - Self.textInsets.left - Self.textInsets.right, 1),
            height: max(height, rowHeight)
        )
        if !textContentView.frame.wiIsNearlyEqual(to: textFrame) {
            textContentView.frame = textFrame
        }

        let containerSize = CGSize(width: textFrame.width, height: CGFloat.greatestFiniteMagnitude)
        if !textContainer.size.wiIsNearlyEqual(to: containerSize) {
            textContainer.size = containerSize
        }
    }

    private func measureTextWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else {
            return 0
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .paragraphStyle: Self.paragraphStyle
        ]
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { CGFloat(ceil((String($0) as NSString).size(withAttributes: attributes).width)) }
            .max() ?? 0
    }

    private func configureHighlights(
        for fragmentView: DOMTreeTextLayoutFragmentView,
        layoutFragmentFrame: CGRect,
        surfaceFrame: CGRect
    ) {
        fragmentView.hoverRowRects = hoverRowRects(surfaceFrame: surfaceFrame)
        fragmentView.selectedRowRects = selectedRowRects(surfaceFrame: surfaceFrame)
        fragmentView.disclosureMarkers = disclosureMarkers(surfaceFrame: surfaceFrame)
        fragmentView.findHighlightRects = findFoundRanges.flatMap {
            textRects(for: $0, layoutFragmentFrame: surfaceFrame)
        }
        fragmentView.currentFindHighlightRects = findHighlightedRanges.flatMap {
            textRects(for: $0, layoutFragmentFrame: surfaceFrame)
        }
        fragmentView.setNeedsDisplay()
        _ = layoutFragmentFrame
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
        return CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: max(bounds.height, 1))
    }

    private func selectedRowRects(surfaceFrame: CGRect) -> [CGRect] {
        guard let selectedNodeID = dom.document.selectedNode?.id else {
            return []
        }
        return rowRects(for: selectedNodeID, surfaceFrame: surfaceFrame)
    }

    private func hoverRowRects(surfaceFrame: CGRect) -> [CGRect] {
        guard let hoveredNodeID else {
            return []
        }
        return rowRects(for: hoveredNodeID, surfaceFrame: surfaceFrame)
    }

    private func rowRects(for nodeID: DOMNodeModel.ID, surfaceFrame: CGRect) -> [CGRect] {
        guard let rowIndex = rowIndexByNodeID[nodeID],
              rows.indices.contains(rowIndex)
        else {
            return []
        }
        let highlightHeight = min(rowHeight, ceil(Self.font.lineHeight))
        let highlightY = CGFloat(rowIndex) * rowHeight + (rowHeight - highlightHeight) / 2
        let rowRect = CGRect(
            x: 0,
            y: highlightY,
            width: max(textContentView.bounds.width, contentSize.width - Self.textInsets.left - Self.textInsets.right),
            height: highlightHeight
        )
        guard rowRect.intersects(surfaceFrame) else {
            return []
        }
        return [rowRect.offsetBy(dx: -surfaceFrame.minX, dy: -surfaceFrame.minY)]
    }

    private func textRects(for range: NSRange, layoutFragmentFrame: CGRect) -> [CGRect] {
        guard let textRange = textRange(for: range) else {
            return []
        }

        var rects: [CGRect] = []
        let fragmentLocalBounds = CGRect(origin: .zero, size: layoutFragmentFrame.size)
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: [.rangeNotRequired]
        ) { _, rect, _, _ in
            let localRect = rect.offsetBy(dx: -layoutFragmentFrame.minX, dy: -layoutFragmentFrame.minY)
            guard localRect.intersects(fragmentLocalBounds) else {
                return true
            }
            rects.append(localRect)
            return true
        }
        return rects
    }

    private func disclosureMarkers(surfaceFrame: CGRect) -> [DOMTreeDisclosureMarker] {
        visibleRows(intersecting: surfaceFrame).compactMap { row in
            guard row.hasDisclosure,
                  row.disclosureRect.intersects(surfaceFrame)
            else {
                return nil
            }

            return DOMTreeDisclosureMarker(
                rect: row.disclosureRect.offsetBy(
                    dx: -surfaceFrame.minX,
                    dy: -surfaceFrame.minY
                ),
                isOpen: row.isOpen
            )
        }
    }

    private func visibleRows(intersecting surfaceFrame: CGRect) -> ArraySlice<DOMTreeLine> {
        guard !rows.isEmpty else {
            return []
        }
        let startIndex = max(0, Int(floor(surfaceFrame.minY / rowHeight)))
        let endIndex = min(rows.count, Int(ceil(surfaceFrame.maxY / rowHeight)) + 1)
        guard startIndex < endIndex else {
            return []
        }
        return rows[startIndex..<endIndex]
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

    private func updateFindHighlightFragmentViews() {
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            configureHighlights(
                for: fragmentView,
                layoutFragmentFrame: fragmentView.layoutFragment.layoutFragmentFrame,
                surfaceFrame: fragmentView.frame
            )
        }
    }

    private func revealPendingSelectedNodeIfPossible() {
        guard let selectedNodeID = pendingRevealSelectedNodeID,
              let rowIndex = rowIndexByNodeID[selectedNodeID],
              rows.indices.contains(rowIndex),
              bounds.width > 0,
              bounds.height > 0
        else {
            return
        }

        let row = rows[rowIndex]
        let markupStartX = CGFloat(row.markupRange.location) * Self.characterWidth
        let rowHeadX = row.hasDisclosure ? row.disclosureRect.minX : markupStartX
        let targetRect = CGRect(
            x: max(0, Self.textInsets.left + rowHeadX - 12),
            y: Self.textInsets.top + CGFloat(rowIndex) * rowHeight,
            width: 1,
            height: rowHeight
        )
        scrollRectToVisible(
            targetRect.insetBy(dx: 0, dy: -rowHeight * 2),
            animated: window != nil
        )
        pendingRevealSelectedNodeID = nil
    }
}

#if DEBUG
extension DOMTreeTextView {
    struct DOMTreeLineSnapshot {
        let text: String
        let depth: Int
        let rowIndex: Int
        let textRange: NSRange
        let markupRange: NSRange
        let markupStartX: CGFloat
        let disclosureRect: CGRect
        let tokenKinds: [String]
        let tokenTexts: [String]
    }

    var renderedTextForTesting: String {
        renderedText
    }

    var rowCountForTesting: Int {
        rows.count
    }

    var renderedLineSnapshotsForTesting: [DOMTreeLineSnapshot] {
        rows.map { row in
            let line = row.text as NSString
            return DOMTreeLineSnapshot(
                text: row.text,
                depth: row.depth,
                rowIndex: row.rowIndex,
                textRange: row.textRange,
                markupRange: row.markupRange,
                markupStartX: CGFloat(row.markupRange.location) * Self.characterWidth,
                disclosureRect: row.disclosureRect,
                tokenKinds: row.tokens.map(\.kind.rawValue),
                tokenTexts: row.tokens.map { line.substring(with: $0.range) }
            )
        }
    }

    var findFoundRangesForTesting: [NSRange] {
        findFoundRanges
    }

    var findHighlightedRangesForTesting: [NSRange] {
        findHighlightedRanges
    }

    func selectRowForTesting(containing text: String) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        select(row.node)
    }

    func toggleRowForTesting(containing text: String) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        toggle(row: row)
    }

    func decorateFindTextForTesting(query: String) {
        clearFindDecorations()
        for range in DOMTreeFindCoordinator.searchRanges(in: renderedText, queryString: query) {
            decorateFindTextRange(range, style: .found)
        }
        if let firstRange = DOMTreeFindCoordinator.searchRanges(in: renderedText, queryString: query).first {
            decorateFindTextRange(firstRange, style: .highlighted)
        }
    }

    func contextMenuForTesting(containing text: String) -> UIMenu? {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return nil
        }
        return makeContextMenu(for: row.node)
    }

    func contextMenuTitlesForTesting(containing text: String) -> [String] {
        contextMenuForTesting(containing: text)?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    func synchronizeDocumentForTesting() {
        reloadTree()
    }

    func selectedRowRectsForTesting() -> [CGRect] {
        selectedRowRects(surfaceFrame: CGRect(origin: .zero, size: textContentView.bounds.size))
    }

    var rowHeightForTesting: CGFloat {
        rowHeight
    }

    var paragraphLineHeightForTesting: CGFloat {
        Self.paragraphStyle.minimumLineHeight
    }

    static func tokenColorForTesting(kind: String, style: UIUserInterfaceStyle) -> UIColor? {
        guard let tokenKind = DOMTreeTokenKind(rawValue: kind) else {
            return nil
        }
        return tokenKind.color(resolvedFor: UITraitCollection(userInterfaceStyle: style))
    }

    static func selectedRowBackgroundColorForTesting(style: UIUserInterfaceStyle) -> UIColor {
        DOMTreeHighlightTheme.webInspector.selectedRowBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
    }
}
#endif

private struct DOMTreeLine {
    let node: DOMNodeModel
    let depth: Int
    let rowIndex: Int
    let text: String
    let textRange: NSRange
    let markupRange: NSRange
    let tokens: [DOMTreeToken]
    let hasDisclosure: Bool
    let isOpen: Bool
    let disclosureRect: CGRect
}

private struct DOMTreeToken {
    let kind: DOMTreeTokenKind
    let range: NSRange
}

private enum DOMTreeTokenKind: String {
    case punctuation
    case tagName
    case attributeName
    case attributeValue
    case text
    case comment
    case doctype
    case fallback

    @MainActor
    func color(resolvedFor traitCollection: UITraitCollection) -> UIColor {
        let theme = DOMTreeHighlightTheme.webInspector
        let dynamicColor = switch self {
        case .punctuation:
            theme.tagPunctuation
        case .tagName:
            theme.nodeName
        case .attributeName:
            theme.nodeAttribute
        case .attributeValue:
            theme.nodeValue
        case .text:
            theme.textSecondary
        case .comment:
            theme.textSecondary
        case .doctype:
            theme.nodeAttribute
        case .fallback:
            theme.textSecondary
        }
        return dynamicColor.resolvedColor(with: traitCollection)
    }
}

private struct DOMTreeHighlightTheme {
    let baseForeground: UIColor
    let textSecondary: UIColor
    let textTertiary: UIColor
    let nodeName: UIColor
    let nodeAttribute: UIColor
    let nodeValue: UIColor
    let tagPunctuation: UIColor
    let disclosure: UIColor
    let selectedRowBackground: UIColor
    let hoverRowBackground: UIColor
    let findBackground: UIColor
    let currentFindBackground: UIColor

    static let webInspector = DOMTreeHighlightTheme(
        baseForeground: .domTreeDynamic(light: 0x111827, dark: 0xF7F9FC),
        textSecondary: .domTreeDynamic(light: 0x475569, dark: 0xA0AFC1),
        textTertiary: .domTreeDynamic(light: 0x6B7280, dark: 0x6E7A88),
        nodeName: .domTreeDynamic(light: 0x0F6BDC, dark: 0x32D4FF),
        nodeAttribute: .domTreeDynamic(light: 0x8A2EC3, dark: 0xEC9EFF),
        nodeValue: .domTreeDynamic(light: 0xB35C00, dark: 0xFFD479),
        tagPunctuation: .domTreeDynamic(light: 0x0F6BDC, dark: 0x32D4FF),
        disclosure: .domTreeDynamic(light: 0x6B7280, dark: 0xA0AFC1),
        selectedRowBackground: .domTreeDynamic(light: 0x0A84FF, dark: 0x0A84FF, lightAlpha: 0.18, darkAlpha: 0.35),
        hoverRowBackground: .domTreeDynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.05),
        findBackground: .domTreeDynamic(light: 0xFFC947, dark: 0xFFDB73, lightAlpha: 0.42, darkAlpha: 0.35),
        currentFindBackground: .domTreeDynamic(light: 0xFFC947, dark: 0xFFDB73, lightAlpha: 0.62, darkAlpha: 0.52)
    )
}

private struct DOMTreeMarkup {
    private(set) var text = ""
    private(set) var tokens: [DOMTreeToken] = []

    mutating func append(_ fragment: String, kind: DOMTreeTokenKind) {
        guard !fragment.isEmpty else {
            return
        }
        let start = (text as NSString).length
        text += fragment
        tokens.append(
            DOMTreeToken(
                kind: kind,
                range: NSRange(location: start, length: (fragment as NSString).length)
            )
        )
    }

    mutating func appendQuotedAttributeValue(_ value: String) {
        append("\"", kind: .attributeValue)
        append(value, kind: .attributeValue)
        append("\"", kind: .attributeValue)
    }

    mutating func appendQuotedText(_ value: String) {
        append("\"", kind: .punctuation)
        append(value, kind: .text)
        append("\"", kind: .punctuation)
    }
}

@MainActor
private enum DOMTreeMarkupBuilder {
    private static let voidElementNames: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"
    ]
    private static let booleanAttributeNames: Set<String> = [
        "allowfullscreen", "async", "autofocus", "autoplay", "checked", "controls", "default", "defer", "disabled",
        "formnovalidate", "hidden", "inert", "ismap", "itemscope", "loop", "multiple", "muted", "nomodule",
        "novalidate", "open", "playsinline", "readonly", "required", "reversed", "selected"
    ]

    static func markup(for node: DOMNodeModel, hasDisclosure: Bool, isOpen: Bool) -> DOMTreeMarkup {
        switch inferredNodeType(for: node) {
        case .element:
            elementMarkup(for: node, hasDisclosure: hasDisclosure, isOpen: isOpen)
        case .text:
            textMarkup(for: node)
        case .comment:
            commentMarkup(for: node)
        case .documentType:
            documentTypeMarkup(for: node)
        case .documentFragment:
            fallbackMarkup("#document-fragment")
        case .cdataSection:
            cdataMarkup(for: node)
        case .processingInstruction:
            processingInstructionMarkup(for: node)
        case .document:
            fallbackMarkup("#document")
        default:
            fallbackMarkup(fallbackPreview(for: node))
        }
    }

    private static func inferredNodeType(for node: DOMNodeModel) -> DOMNodeType {
        if node.nodeType != .unknown {
            return node.nodeType
        }

        let name = (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
        switch name {
        case "#document":
            return .document
        case "!doctype", "#doctype":
            return .documentType
        case "#text":
            return .text
        case "#comment":
            return .comment
        case "#cdata-section":
            return .cdataSection
        case "#document-fragment", "#shadow-root":
            return .documentFragment
        case let name where !name.isEmpty && !name.hasPrefix("#"):
            return .element
        default:
            return .unknown
        }
    }

    private static func elementMarkup(for node: DOMNodeModel, hasDisclosure: Bool, isOpen: Bool) -> DOMTreeMarkup {
        let name = elementName(for: node)
        let isVoid = voidElementNames.contains(name)
        var markup = DOMTreeMarkup()
        markup.append("<", kind: .punctuation)
        markup.append(name, kind: .tagName)
        for attribute in node.attributes {
            append(attribute: attribute, to: &markup)
        }
        markup.append(">", kind: .punctuation)

        if !isVoid {
            if hasDisclosure, !isOpen {
                markup.append("...", kind: .fallback)
                markup.append("</", kind: .punctuation)
                markup.append(name, kind: .tagName)
                markup.append(">", kind: .punctuation)
            } else if !hasDisclosure {
                markup.append("</", kind: .punctuation)
                markup.append(name, kind: .tagName)
                markup.append(">", kind: .punctuation)
            }
        }
        return markup
    }

    private static func append(attribute: DOMAttribute, to markup: inout DOMTreeMarkup) {
        let name = attribute.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }
        markup.append(" ", kind: .fallback)
        markup.append(name, kind: .attributeName)
        guard !isBooleanAttribute(attribute) else {
            return
        }
        markup.append("=", kind: .attributeValue)
        markup.appendQuotedAttributeValue(escapedAttributeValue(attribute.value))
    }

    private static func textMarkup(for node: DOMNodeModel) -> DOMTreeMarkup {
        let text = escapedTextValue(normalizedValue(for: node))
        guard !text.isEmpty else {
            return fallbackMarkup("#text")
        }
        var markup = DOMTreeMarkup()
        markup.appendQuotedText(text)
        return markup
    }

    private static func commentMarkup(for node: DOMNodeModel) -> DOMTreeMarkup {
        var markup = DOMTreeMarkup()
        markup.append("<!--", kind: .punctuation)
        let text = escapedCommentValue(normalizedValue(for: node))
        if !text.isEmpty {
            markup.append(" ", kind: .fallback)
            markup.append(text, kind: .comment)
            markup.append(" ", kind: .fallback)
        }
        markup.append("-->", kind: .punctuation)
        return markup
    }

    private static func documentTypeMarkup(for node: DOMNodeModel) -> DOMTreeMarkup {
        var markup = DOMTreeMarkup()
        let name = elementName(for: node, fallback: "html")
        markup.append("<!", kind: .punctuation)
        markup.append("DOCTYPE", kind: .doctype)
        markup.append(" ", kind: .fallback)
        markup.append(name, kind: .doctype)
        markup.append(">", kind: .punctuation)
        return markup
    }

    private static func cdataMarkup(for node: DOMNodeModel) -> DOMTreeMarkup {
        var markup = DOMTreeMarkup()
        markup.append("<![CDATA[", kind: .punctuation)
        markup.append(lineSafeValue(normalizedValue(for: node)), kind: .text)
        markup.append("]]>", kind: .punctuation)
        return markup
    }

    private static func processingInstructionMarkup(for node: DOMNodeModel) -> DOMTreeMarkup {
        var markup = DOMTreeMarkup()
        markup.append("<?", kind: .punctuation)
        markup.append(elementName(for: node, fallback: "instruction"), kind: .tagName)
        let text = lineSafeValue(normalizedValue(for: node))
        if !text.isEmpty {
            markup.append(" ", kind: .fallback)
            markup.append(text, kind: .text)
        }
        markup.append("?>", kind: .punctuation)
        return markup
    }

    private static func fallbackMarkup(_ text: String) -> DOMTreeMarkup {
        var markup = DOMTreeMarkup()
        markup.append(text.isEmpty ? "(empty)" : lineSafeValue(text), kind: .fallback)
        return markup
    }

    private static func isBooleanAttribute(_ attribute: DOMAttribute) -> Bool {
        attribute.value.isEmpty && booleanAttributeNames.contains(attribute.name.lowercased())
    }

    private static func elementName(for node: DOMNodeModel, fallback: String = "element") -> String {
        let rawName: String
        if !node.localName.isEmpty {
            rawName = node.localName
        } else if !node.nodeName.isEmpty {
            rawName = node.nodeName
        } else {
            rawName = fallback
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? fallback : name).lowercased()
    }

    private static func fallbackPreview(for node: DOMNodeModel) -> String {
        if !node.preview.isEmpty {
            return node.preview
        }
        if !node.nodeValue.isEmpty {
            return node.nodeValue
        }
        if !node.localName.isEmpty {
            return node.localName
        }
        return node.nodeName
    }

    private static func normalizedValue(for node: DOMNodeModel) -> String {
        let source = node.nodeValue.isEmpty ? node.preview : node.nodeValue
        return source
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapedAttributeValue(_ value: String) -> String {
        lineSafeValue(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapedTextValue(_ value: String) -> String {
        lineSafeValue(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapedCommentValue(_ value: String) -> String {
        lineSafeValue(value)
            .replacingOccurrences(of: "-->", with: "--\\>")
    }

    private static func lineSafeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct DOMTreeDisclosureMarker {
    let rect: CGRect
    let isOpen: Bool
}

private final class DOMTreeTextContentView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class DOMTreeTextLayoutFragmentView: UIView {
    let layoutFragment: NSTextLayoutFragment
    var layoutFragmentDrawPoint = CGPoint.zero
    var hoverRowRects: [CGRect] = []
    var selectedRowRects: [CGRect] = []
    var disclosureMarkers: [DOMTreeDisclosureMarker] = []
    var findHighlightRects: [CGRect] = []
    var currentFindHighlightRects: [CGRect] = []
    private static let disclosureImage = UIImage(systemName: "triangle.fill")

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

        context.saveGState()
        context.setFillColor(DOMTreeHighlightTheme.webInspector.hoverRowBackground.resolvedColor(with: traitCollection).cgColor)
        for rowRect in hoverRowRects where rowRect.intersects(rect) {
            context.fill(rowRect)
        }
        context.restoreGState()

        context.saveGState()
        context.setFillColor(DOMTreeHighlightTheme.webInspector.selectedRowBackground.resolvedColor(with: traitCollection).cgColor)
        for rowRect in selectedRowRects where rowRect.intersects(rect) {
            context.fill(rowRect)
        }
        context.restoreGState()

        if let disclosureImage = Self.disclosureImage?.withTintColor(
            DOMTreeHighlightTheme.webInspector.disclosure.resolvedColor(with: traitCollection),
            renderingMode: .alwaysOriginal
        ) {
            for marker in disclosureMarkers where marker.rect.intersects(rect) {
                drawDisclosureMarker(marker, image: disclosureImage)
            }
        }

        context.saveGState()
        context.setFillColor(DOMTreeHighlightTheme.webInspector.findBackground.resolvedColor(with: traitCollection).cgColor)
        for findRect in findHighlightRects where findRect.intersects(rect) {
            context.fill(findRect)
        }
        context.restoreGState()

        context.saveGState()
        context.setFillColor(DOMTreeHighlightTheme.webInspector.currentFindBackground.resolvedColor(with: traitCollection).cgColor)
        for findRect in currentFindHighlightRects where findRect.intersects(rect) {
            context.fill(findRect)
        }
        context.restoreGState()

        layoutFragment.draw(at: layoutFragmentDrawPoint, in: context)
    }

    private func drawDisclosureMarker(_ marker: DOMTreeDisclosureMarker, image: UIImage) {
        let side = min(marker.rect.width, marker.rect.height, DOMTreeTextView.iconSide)
        let drawRect = CGRect(
            x: marker.rect.midX - side / 2,
            y: marker.rect.midY - side / 2,
            width: side,
            height: side
        )

        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        context.saveGState()
        context.translateBy(x: drawRect.midX, y: drawRect.midY)
        context.rotate(by: marker.isOpen ? .pi : .pi / 2)
        image.draw(in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        context.restoreGState()
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

private extension UIColor {
    static func domTreeDynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1.0, darkAlpha: CGFloat = 1.0) -> UIColor {
        UIColor { traitCollection in
            let isDark = traitCollection.userInterfaceStyle == .dark
            return domTreeColor(
                hex: isDark ? dark : light,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }

    static func domTreeColor(hex: UInt32, alpha: CGFloat = 1.0) -> UIColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
