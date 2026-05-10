#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class DOMTreeTextView: UIScrollView, @preconcurrency NSTextViewportLayoutControllerDelegate, UITextInput, UITextInteractionDelegate {
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
    private lazy var textSelectionInteraction: UITextInteraction = {
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.delegate = self
        interaction.textInput = self
        return interaction
    }()
    private lazy var textInputTokenizer = UITextInputStringTokenizer(textInput: self)

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
    private var multiSelectedNodeIDs: Set<DOMNodeModel.ID> = []
    private var multiSelectionLastNodeID: DOMNodeModel.ID?
    private var multiSelectionShiftAnchorNodeID: DOMNodeModel.ID?
    private var multiSelectionShiftRangeNodeIDs: Set<DOMNodeModel.ID> = []
    private var menuAnchorButton: UIButton?
    private var selectedTextNSRange = NSRange(location: 0, length: 0)
    private var markedTextNSRange: NSRange?
    private var markedTextStyleStorage: [NSAttributedString.Key: Any]?
    weak var inputDelegate: UITextInputDelegate?
#if DEBUG
    private var lastPresentedDOMMenuTitles: [String] = []
#endif

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
                title: wiLocalized("Extend Selection Up"),
                action: #selector(extendMultiSelectionUp),
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: .shift,
                discoverabilityTitle: wiLocalized("Extend Selection Up")
            ),
            UIKeyCommand(
                title: wiLocalized("Extend Selection Down"),
                action: #selector(extendMultiSelectionDown),
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: .shift,
                discoverabilityTitle: wiLocalized("Extend Selection Down")
            ),
            UIKeyCommand(
                title: wiLocalized("Select All"),
                action: #selector(selectAllRenderedRows),
                input: "a",
                modifierFlags: .command,
                discoverabilityTitle: wiLocalized("Select All")
            ),
            UIKeyCommand(
                title: wiLocalized("Find"),
                action: #selector(showFindNavigator),
                input: "f",
                modifierFlags: .command,
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
        lastUsedFragmentViews = Set(textContentView.subviews.compactMap { $0 as? DOMTreeTextLayoutFragmentView })
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

        dismissDOMMenuAnchor()
        clearTextSelection()
        let location = recognizer.location(in: textContentView)
        if row.hasDisclosure,
           location.x >= row.disclosureRect.minX,
           location.x <= row.disclosureRect.maxX {
            toggle(row: row)
        } else if recognizer.modifierFlags.contains(.shift) {
            extendMultiSelection(to: row)
        } else if recognizer.modifierFlags.contains(.command) || recognizer.modifierFlags.contains(.control) {
            toggleMultiSelection(row: row)
        } else {
            clearMultiSelection(keepingLast: row.node.id)
            select(row.node)
        }
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let row = row(at: recognizer.location(in: textContentView))
        else {
            return
        }

        let nodes: [DOMNodeModel]
        if multiSelectedNodeIDs.count > 1, multiSelectedNodeIDs.contains(row.node.id) {
            nodes = multiSelectedNodesInDisplayOrder()
        } else {
            clearMultiSelection(keepingLast: row.node.id)
            nodes = [row.node]
            select(row.node)
        }
        presentDOMMenu(for: nodes, at: recognizer.location(in: self))
    }

    @objc private func extendMultiSelectionUp() {
        extendMultiSelectionByKeyboard(delta: -1)
    }

    @objc private func extendMultiSelectionDown() {
        extendMultiSelectionByKeyboard(delta: 1)
    }

    @objc private func selectAllRenderedRows() {
        guard !rows.isEmpty else {
            clearMultiSelection(keepingLast: nil)
            return
        }
        multiSelectedNodeIDs = Set(rows.map(\.node.id))
        multiSelectionLastNodeID = rows.last?.node.id
        multiSelectionShiftAnchorNodeID = rows.first?.node.id
        multiSelectionShiftRangeNodeIDs = multiSelectedNodeIDs
        updateContentDecorations()
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
                updateContentDecorations()
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

    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        let contentPoint = convert(point, to: textContentView)
        if let row = row(at: contentPoint),
           row.hasDisclosure,
           contentPoint.x >= row.disclosureRect.minX,
           contentPoint.x <= row.disclosureRect.maxX {
            return false
        }
        dismissDOMMenuAnchor()
        clearMultiSelection(keepingLast: multiSelectionLastNodeID)
        return true
    }

    func interactionWillBegin(_ interaction: UITextInteraction) {
        dismissDOMMenuAnchor()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return selectedTextNSRange.length > 0
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard selectedTextNSRange.length > 0,
              let text = text(in: DOMTreeTextRange(range: selectedTextNSRange))
        else {
            return
        }
        UIPasteboard.general.string = text
    }

    func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let range = clampedTextRange(nsRange(from: textRange))
        guard range.length > 0 else {
            return UIMenu(children: [])
        }
        return makeTextSelectionEditMenu(for: range)
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
        tapRecognizer.buttonMaskRequired = .primary
        addGestureRecognizer(tapRecognizer)

        let secondaryClickRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryClickRecognizer.buttonMaskRequired = .secondary
        secondaryClickRecognizer.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        addGestureRecognizer(secondaryClickRecognizer)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
        addInteraction(textSelectionInteraction)
        for gestureRecognizer in textSelectionInteraction.gesturesForFailureRequirements {
            gestureRecognizer.require(toFail: tapRecognizer)
        }
        addInteraction(findCoordinator.findInteraction)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (self: DOMTreeTextView, _) in
            self.reapplyTextAttributes()
            self.updateDecorations()
        }
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
        reconcileMultiSelectionAfterReload()
        renderedText = buildResult.text
        clampTextSelectionAfterTextChange()
        measuredTextWidth = measureTextWidth(renderedText)
        requestedChildNodeIDs = requestedChildNodeIDs.filter { nodeID in
            dom.document.node(id: nodeID) != nil
        }
        resetTextFragmentViews()
        rebuildTextStorage()

        clearFindDecorations()
        findCoordinator.invalidateResultsAfterTextChange()
        updateTextLayoutGeometry()
        updateContentDecorations()
        setNeedsLayout()
        revealPendingSelectedNodeIfPossible()
    }

    private func prepareSelectionForRendering() {
        let selectedNode = dom.document.selectedNode
        let selectedNodeID = selectedNode?.id
        if selectedNodeID != lastObservedSelectedNodeID {
            if let selectedNodeID, !multiSelectedNodeIDs.contains(selectedNodeID) {
                clearMultiSelection(keepingLast: selectedNodeID)
            } else if selectedNodeID == nil {
                clearMultiSelection(keepingLast: nil)
            }
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
            let hasDisclosure = nodeHasDisclosure(node)
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

    private func nodeHasDisclosure(_ node: DOMNodeModel) -> Bool {
        node.childCount > 0
            || !node.children.isEmpty
            || (!node.childCountIsKnown && DOMTreeMarkupBuilder.canContainChildNodes(node))
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
        multiSelectionLastNodeID = node.id
        Task { @MainActor [dom] in
            await dom.selectNode(node)
        }
    }

    private func toggleMultiSelection(row: DOMTreeLine) {
        var selectedIDs = multiSelectedNodeIDs
        if selectedIDs.isEmpty {
            if let lastNodeID = multiSelectionLastNodeID,
               rowIndexByNodeID[lastNodeID] != nil {
                selectedIDs.insert(lastNodeID)
            } else if let selectedNodeID = dom.document.selectedNode?.id,
                      rowIndexByNodeID[selectedNodeID] != nil {
                selectedIDs.insert(selectedNodeID)
            }
        }

        if selectedIDs.contains(row.node.id) {
            selectedIDs.remove(row.node.id)
        } else {
            selectedIDs.insert(row.node.id)
        }
        if selectedIDs.isEmpty {
            selectedIDs.insert(row.node.id)
        }

        multiSelectedNodeIDs = selectedIDs
        multiSelectionLastNodeID = row.node.id
        multiSelectionShiftAnchorNodeID = nil
        multiSelectionShiftRangeNodeIDs.removeAll(keepingCapacity: true)
        updateContentDecorations()
    }

    private func extendMultiSelection(to row: DOMTreeLine) {
        guard let anchorNodeID = multiSelectionAnchorNodeID() else {
            return
        }
        let rangeRows = rowsBetween(anchorNodeID, row.node.id)
        let rangeNodeIDs = Set(rangeRows.map(\.node.id))
        guard !rangeNodeIDs.isEmpty else {
            return
        }

        var selectedIDs = multiSelectedNodeIDs
        if selectedIDs.isEmpty,
           let selectedNodeID = dom.document.selectedNode?.id,
           rowIndexByNodeID[selectedNodeID] != nil {
            selectedIDs.insert(selectedNodeID)
        }
        selectedIDs.subtract(multiSelectionShiftRangeNodeIDs)
        selectedIDs.formUnion(rangeNodeIDs)

        multiSelectedNodeIDs = selectedIDs
        multiSelectionShiftAnchorNodeID = anchorNodeID
        multiSelectionShiftRangeNodeIDs = rangeNodeIDs
        multiSelectionLastNodeID = row.node.id
        updateContentDecorations()
    }

    private func extendMultiSelectionByKeyboard(delta: Int) {
        guard !rows.isEmpty else {
            return
        }

        let focusedNodeID = multiSelectionLastNodeID
            ?? dom.document.selectedNode?.id
            ?? rows.first?.node.id
        guard let focusedNodeID,
              let focusedIndex = rowIndexByNodeID[focusedNodeID]
        else {
            return
        }

        let targetIndex = min(max(focusedIndex + delta, 0), rows.count - 1)
        guard targetIndex != focusedIndex else {
            return
        }
        let targetRow = rows[targetIndex]
        extendMultiSelection(to: targetRow)
        scrollRowToVisible(targetRow)
    }

    private func multiSelectionAnchorNodeID() -> DOMNodeModel.ID? {
        if let anchorNodeID = multiSelectionShiftAnchorNodeID,
           rowIndexByNodeID[anchorNodeID] != nil {
            return anchorNodeID
        }
        if let lastNodeID = multiSelectionLastNodeID,
           rowIndexByNodeID[lastNodeID] != nil {
            return lastNodeID
        }
        if let selectedNodeID = dom.document.selectedNode?.id,
           rowIndexByNodeID[selectedNodeID] != nil {
            return selectedNodeID
        }
        return rows.first?.node.id
    }

    private func rowsBetween(_ firstNodeID: DOMNodeModel.ID, _ secondNodeID: DOMNodeModel.ID) -> ArraySlice<DOMTreeLine> {
        guard let firstIndex = rowIndexByNodeID[firstNodeID],
              let secondIndex = rowIndexByNodeID[secondNodeID]
        else {
            return []
        }
        let lowerBound = min(firstIndex, secondIndex)
        let upperBound = max(firstIndex, secondIndex)
        return rows[lowerBound...upperBound]
    }

    private func clearMultiSelection(keepingLast nodeID: DOMNodeModel.ID?) {
        multiSelectedNodeIDs.removeAll(keepingCapacity: true)
        multiSelectionLastNodeID = nodeID
        multiSelectionShiftAnchorNodeID = nil
        multiSelectionShiftRangeNodeIDs.removeAll(keepingCapacity: true)
        updateContentDecorations()
    }

    private func reconcileMultiSelectionAfterReload() {
        let visibleNodeIDs = Set(rows.map(\.node.id))
        multiSelectedNodeIDs.formIntersection(visibleNodeIDs)
        multiSelectionShiftRangeNodeIDs.formIntersection(visibleNodeIDs)
        if let nodeID = multiSelectionLastNodeID, !visibleNodeIDs.contains(nodeID) {
            multiSelectionLastNodeID = nil
        }
        if let nodeID = multiSelectionShiftAnchorNodeID, !visibleNodeIDs.contains(nodeID) {
            multiSelectionShiftAnchorNodeID = nil
            multiSelectionShiftRangeNodeIDs.removeAll(keepingCapacity: true)
        }
        if multiSelectedNodeIDs.isEmpty {
            multiSelectionShiftRangeNodeIDs.removeAll(keepingCapacity: true)
        }
    }

    private func multiSelectedNodesInDisplayOrder() -> [DOMNodeModel] {
        rows.compactMap { row in
            multiSelectedNodeIDs.contains(row.node.id) ? row.node : nil
        }
    }

    private func scrollRowToVisible(_ row: DOMTreeLine) {
        let targetRect = CGRect(
            x: Self.textInsets.left + (row.hasDisclosure ? row.disclosureRect.minX : CGFloat(row.markupRange.location) * Self.characterWidth),
            y: Self.textInsets.top + CGFloat(row.rowIndex) * rowHeight,
            width: 1,
            height: rowHeight
        )
        scrollRectToVisible(targetRect.insetBy(dx: 0, dy: -rowHeight), animated: true)
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
        updateContentDecorations()
    }

    private func presentDOMMenu(for nodes: [DOMNodeModel], at location: CGPoint) {
        let menu = makeDOMMenu(for: nodes)
#if DEBUG
        lastPresentedDOMMenuTitles = menu.children.compactMap { ($0 as? UIAction)?.title }
#endif

        dismissDOMMenuAnchor()
        let button = UIButton(type: .system)
        button.alpha = 0.01
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.frame = CGRect(
            x: contentOffset.x + location.x,
            y: contentOffset.y + location.y,
            width: 1,
            height: 1
        )
        addSubview(button)
        menuAnchorButton = button
        button.performPrimaryAction()
        Task { @MainActor [weak self, weak button] in
            guard let self, self.menuAnchorButton === button else {
                return
            }
            button?.isUserInteractionEnabled = false
        }
    }

    private func dismissDOMMenuAnchor() {
        menuAnchorButton?.menu = nil
        menuAnchorButton?.removeFromSuperview()
        menuAnchorButton = nil
    }

    private func makeDOMMenu(for nodes: [DOMNodeModel]) -> UIMenu {
        if nodes.count > 1 {
            makeMultiNodeMenu(for: nodes)
        } else if let node = nodes.first {
            makeContextMenu(for: node)
        } else {
            UIMenu(children: [])
        }
    }

    private func makeTextSelectionEditMenu(for range: NSRange) -> UIMenu {
        let selectedRows = rowsIntersectingTextRange(range)
        let nodes = uniqueNodesInDisplayOrder(for: selectedRows)
        guard !nodes.isEmpty else {
            return UIMenu(children: [])
        }

        if selectedRows.count > 1 {
            return makeMultiNodeMenu(for: nodes)
        }

        let copyText = UIAction(
            title: "Copy",
            image: UIImage(systemName: "doc.on.doc")
        ) { [weak self] _ in
            guard let self,
                  let text = self.text(in: DOMTreeTextRange(range: range)),
                  !text.isEmpty
            else {
                return
            }
            UIPasteboard.general.string = text
        }

        return UIMenu(children: [copyText] + makeDOMMenu(for: nodes).children)
    }

    private func rowsIntersectingTextRange(_ range: NSRange) -> [DOMTreeLine] {
        let range = clampedTextRange(range)
        guard range.length > 0 else {
            return []
        }
        let lowerBound = range.location
        let upperBound = NSMaxRange(range)
        return rows.filter { row in
            lowerBound < NSMaxRange(row.textRange) && upperBound > row.textRange.location
        }
    }

    private func uniqueNodesInDisplayOrder(for rows: [DOMTreeLine]) -> [DOMNodeModel] {
        var seenNodeIDs: Set<DOMNodeModel.ID> = []
        return rows.compactMap { row in
            seenNodeIDs.insert(row.node.id).inserted ? row.node : nil
        }
    }

    private func makeMultiNodeMenu(for nodes: [DOMNodeModel]) -> UIMenu {
        let copyHTML = UIAction(title: "Copy HTML") { [weak self] _ in
            guard let self else {
                return
            }
            Task { @MainActor [dom] in
                guard let text = try? await dom.copyHTML(for: nodes), !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            }
        }

        let deleteNodes = UIAction(
            title: "Delete Nodes",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            guard let self else {
                return
            }
            Task { @MainActor [dom, undoManager] in
                try? await dom.deleteNodes(nodes, undoManager: undoManager)
            }
        }

        return UIMenu(children: [copyHTML, deleteNodes])
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
        applyDisclosureAttachments(to: textStorage)
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            fragmentView.setNeedsDisplay()
        }
    }

    private func rebuildTextStorage() {
        let attributedText = NSMutableAttributedString(
            string: renderedText.isEmpty ? "\n" : renderedText,
            attributes: baseTextAttributes()
        )
        applyRowAttributes(to: attributedText)
        applyDisclosureAttachments(to: attributedText)
        textContentStorage.performEditingTransaction {
            textStorage.setAttributedString(attributedText)
        }
        invalidateTextLayout()
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
        updateContentDecorations()
    }

    private func resetTextFragmentViews() {
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            fragmentView.removeFromSuperview()
        }
        fragmentViewMap.removeAllObjects()
        lastUsedFragmentViews.removeAll(keepingCapacity: true)
    }

    private func invalidateTextLayout() {
        layoutManager.invalidateLayout(for: textContentStorage.documentRange)
        layoutManager.textSelectionNavigation.flushLayoutCache()
    }

    private func applyDisclosureAttachments(to attributedText: NSMutableAttributedString) {
        for row in rows where row.hasDisclosure {
            let range = NSRange(
                location: row.textRange.location + row.depth * Self.indentSpacesPerDepth,
                length: 1
            )
            guard NSMaxRange(range) <= attributedText.length else {
                continue
            }
            attributedText.replaceCharacters(
                in: range,
                with: disclosureAttachmentString(isOpen: row.isOpen)
            )
        }
    }

    private func disclosureAttachmentString(isOpen: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = Self.disclosureImage(
            isOpen: isOpen,
            color: DOMTreeHighlightTheme.webInspector.disclosure.resolvedColor(with: traitCollection)
        )
        attachment.bounds = CGRect(
            x: 0,
            y: (Self.font.capHeight - Self.iconSide) / 2,
            width: Self.iconSide,
            height: Self.iconSide
        )

        let attributedString = NSMutableAttributedString(attachment: attachment)
        attributedString.addAttributes(baseTextAttributes(), range: NSRange(location: 0, length: attributedString.length))
        return attributedString
    }

    private static func disclosureImage(isOpen: Bool, color: UIColor) -> UIImage? {
        guard let image = UIImage(
            systemName: "triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSide, weight: .regular)
        )?.withTintColor(color, renderingMode: .alwaysOriginal) else {
            return nil
        }

        let side = iconSide
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.translateBy(x: side / 2, y: side / 2)
            context.rotate(by: isOpen ? .pi : .pi / 2)
            image.draw(in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
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
        surfaceFrame: CGRect
    ) {
        fragmentView.findHighlightRects = findFoundRanges.flatMap {
            textRects(for: $0, layoutFragmentFrame: surfaceFrame)
        }
        fragmentView.currentFindHighlightRects = findHighlightedRanges.flatMap {
            textRects(for: $0, layoutFragmentFrame: surfaceFrame)
        }
        fragmentView.setNeedsDisplay()
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

    private func selectedContentRowRects() -> [CGRect] {
        guard multiSelectedNodeIDs.isEmpty else {
            return []
        }
        guard let selectedNodeID = dom.document.selectedNode?.id else {
            return []
        }
        return rowRects(for: selectedNodeID)
    }

    private func multiSelectionContentRowRects() -> [CGRect] {
        rows.flatMap { row in
            multiSelectedNodeIDs.contains(row.node.id) ? [contentRowRect(rowIndex: row.rowIndex)] : []
        }
    }

    private func hoverContentRowRects() -> [CGRect] {
        guard let hoveredNodeID else {
            return []
        }
        return rowRects(for: hoveredNodeID)
    }

    private func rowRects(for nodeID: DOMNodeModel.ID) -> [CGRect] {
        guard let rowIndex = rowIndexByNodeID[nodeID],
              rows.indices.contains(rowIndex)
        else {
            return []
        }
        return [contentRowRect(rowIndex: rowIndex)]
    }

    private func contentRowRect(rowIndex: Int) -> CGRect {
        let highlightHeight = min(rowHeight, ceil(Self.font.lineHeight))
        let highlightY = CGFloat(rowIndex) * rowHeight + (rowHeight - highlightHeight) / 2
        return CGRect(
            x: 0,
            y: highlightY,
            width: max(textContentView.bounds.width, contentSize.width - Self.textInsets.left - Self.textInsets.right),
            height: highlightHeight
        )
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

    private func updateDecorations() {
        updateContentDecorations()
        updateFindHighlightFragmentViews()
    }

    private func updateContentDecorations() {
        textContentView.hoverRowRects = hoverContentRowRects()
        textContentView.selectedRowRects = selectedContentRowRects()
        textContentView.multiSelectedRowRects = multiSelectionContentRowRects()
        textContentView.setNeedsDisplay()
    }

    private func updateFindHighlightFragmentViews() {
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            configureHighlights(
                for: fragmentView,
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

extension DOMTreeTextView {
    var hasText: Bool {
        !renderedText.isEmpty
    }

    func insertText(_ text: String) {}

    func deleteBackward() {}

    var selectedTextRange: UITextRange? {
        get { DOMTreeTextRange(range: selectedTextNSRange) }
        set { setSelectedTextRange(newValue) }
    }

    var markedTextRange: UITextRange? {
        markedTextNSRange.map(DOMTreeTextRange.init(range:))
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { markedTextStyleStorage }
        set { markedTextStyleStorage = newValue }
    }

    var beginningOfDocument: UITextPosition {
        DOMTreeTextPosition(offset: 0)
    }

    var endOfDocument: UITextPosition {
        DOMTreeTextPosition(offset: renderedTextUTF16Length)
    }

    var tokenizer: UITextInputTokenizer {
        textInputTokenizer
    }

    var textInputView: UIView {
        self
    }

    func text(in range: UITextRange) -> String? {
        let range = clampedTextRange(nsRange(from: range))
        guard range.length > 0 else {
            return ""
        }
        return (renderedText as NSString).substring(with: range)
    }

    func replace(_ range: UITextRange, withText text: String) {}

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        markedTextNSRange = markedText.map { _ in selectedTextNSRange }
    }

    func unmarkText() {
        markedTextNSRange = nil
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let startOffset = offset(from: fromPosition)
        let endOffset = offset(from: toPosition)
        let lower = min(startOffset, endOffset)
        let upper = max(startOffset, endOffset)
        return DOMTreeTextRange(range: clampedTextRange(NSRange(location: lower, length: upper - lower)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        DOMTreeTextPosition(offset: clampedTextOffset(self.offset(from: position) + offset))
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
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

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = offset(from: position)
        let rhs = offset(from: other)
        if lhs == rhs {
            return .orderedSame
        }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        offset(from: toPosition) - offset(from: from)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        let range = nsRange(from: range)
        let offset = switch direction {
        case .left, .up:
            range.location
        case .right, .down:
            NSMaxRange(range)
        @unknown default:
            range.location
        }
        return DOMTreeTextPosition(offset: clampedTextOffset(offset))
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
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
        return DOMTreeTextRange(range: clampedTextRange(range))
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .zero
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        let offset = offset(from: position)
        let row = row(containingTextOffset: offset) ?? rows.last
        guard let row else {
            return .zero
        }
        let column = min(max(0, offset - row.textRange.location), row.textRange.length)
        let localRect = CGRect(
            x: CGFloat(column) * Self.characterWidth,
            y: CGFloat(row.rowIndex) * rowHeight,
            width: 2,
            height: rowHeight
        )
        return textContentView.convert(localRect, to: self)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
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
                DOMTreeTextSelectionRect(
                    rect: self.textContentView.convert(rect, to: self),
                    containsStart: rects.isEmpty,
                    containsEnd: false
                )
            )
            return true
        }
        if let lastRect = rects.last as? DOMTreeTextSelectionRect {
            lastRect.containsSelectionEnd = true
        }
        return rects
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        DOMTreeTextPosition(offset: textOffset(at: point))
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        let range = clampedTextRange(nsRange(from: range))
        return DOMTreeTextPosition(offset: min(max(textOffset(at: point), range.location), NSMaxRange(range)))
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        let offset = textOffset(at: point)
        return DOMTreeTextRange(
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

    private func clearTextSelection() {
        setSelectedTextRange(DOMTreeTextRange(range: NSRange(location: 0, length: 0)))
    }

    private func clampTextSelectionAfterTextChange() {
        selectedTextNSRange = clampedTextRange(selectedTextNSRange)
        if let markedTextNSRange {
            self.markedTextNSRange = clampedTextRange(markedTextNSRange)
        }
    }

    private func nsRange(from range: UITextRange) -> NSRange {
        guard let range = range as? DOMTreeTextRange else {
            return NSRange(location: 0, length: 0)
        }
        return range.range
    }

    private func offset(from position: UITextPosition) -> Int {
        guard let position = position as? DOMTreeTextPosition else {
            return 0
        }
        return clampedTextOffset(position.offset)
    }

    private func clampedTextOffset(_ offset: Int) -> Int {
        min(max(0, offset), renderedTextUTF16Length)
    }

    private func textOffset(at point: CGPoint) -> Int {
        let contentPoint = convert(point, to: textContentView)
        guard let row = row(at: contentPoint) else {
            if contentPoint.y < 0 {
                return 0
            }
            return renderedTextUTF16Length
        }
        let column = min(
            max(0, Int(round(contentPoint.x / Self.characterWidth))),
            row.textRange.length
        )
        return clampedTextOffset(row.textRange.location + column)
    }

    private func row(containingTextOffset offset: Int) -> DOMTreeLine? {
        let offset = clampedTextOffset(offset)
        return rows.first { row in
            offset >= row.textRange.location && offset <= NSMaxRange(row.textRange)
        }
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
        let hasDisclosure: Bool
        let isOpen: Bool
        let tokenKinds: [String]
        let tokenTexts: [String]
    }

    struct DisclosureAttachmentSnapshot {
        let text: String
        let column: Int
        let expectedColumn: Int
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
                hasDisclosure: row.hasDisclosure,
                isOpen: row.isOpen,
                tokenKinds: row.tokens.map(\.kind.rawValue),
                tokenTexts: row.tokens.map { line.substring(with: $0.range) }
            )
        }
    }

    var disclosureAttachmentSnapshotsForTesting: [DisclosureAttachmentSnapshot] {
        var snapshots: [DisclosureAttachmentSnapshot] = []
        for row in rows where row.hasDisclosure {
            let location = row.textRange.location + row.depth * Self.indentSpacesPerDepth
            guard location < textStorage.length else {
                continue
            }
            let character = (textStorage.string as NSString).character(at: location)
            guard character == 0xFFFC else {
                continue
            }
            snapshots.append(
                DisclosureAttachmentSnapshot(
                    text: row.text,
                    column: location - row.textRange.location,
                    expectedColumn: row.depth * Self.indentSpacesPerDepth
                )
            )
        }
        return snapshots
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

    func primaryClickRowForTesting(containing text: String, modifiers: UIKeyModifierFlags = []) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        dismissDOMMenuAnchor()
        clearTextSelection()
        if modifiers.contains(.shift) {
            extendMultiSelection(to: row)
        } else if modifiers.contains(.command) || modifiers.contains(.control) {
            toggleMultiSelection(row: row)
        } else {
            clearMultiSelection(keepingLast: row.node.id)
            multiSelectionLastNodeID = row.node.id
        }
    }

    func secondaryClickMenuTitlesForTesting(containing text: String) -> [String] {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return []
        }
        let nodes: [DOMNodeModel]
        if multiSelectedNodeIDs.count > 1, multiSelectedNodeIDs.contains(row.node.id) {
            nodes = multiSelectedNodesInDisplayOrder()
        } else {
            clearMultiSelection(keepingLast: row.node.id)
            nodes = [row.node]
        }
        let menu = makeDOMMenu(for: nodes)
        let titles = menu.children.compactMap { ($0 as? UIAction)?.title }
        lastPresentedDOMMenuTitles = titles
        return titles
    }

    var multiSelectedLocalIDsForTesting: [UInt64] {
        rows.compactMap { row in
            multiSelectedNodeIDs.contains(row.node.id) ? row.node.localID : nil
        }
    }

    var lastPresentedDOMMenuTitlesForTesting: [String] {
        lastPresentedDOMMenuTitles
    }

    func selectTextForTesting(_ text: String) {
        let nsText = renderedText as NSString
        let range = nsText.range(of: text)
        guard range.location != NSNotFound else {
            return
        }
        setSelectedTextRange(DOMTreeTextRange(range: range))
    }

    func selectTextForTesting(from startText: String, through endText: String) {
        let nsText = renderedText as NSString
        let startRange = nsText.range(of: startText)
        let endRange = nsText.range(of: endText)
        guard startRange.location != NSNotFound,
              endRange.location != NSNotFound
        else {
            return
        }

        let lowerBound = min(startRange.location, endRange.location)
        let upperBound = max(NSMaxRange(startRange), NSMaxRange(endRange))
        setSelectedTextRange(DOMTreeTextRange(range: NSRange(location: lowerBound, length: upperBound - lowerBound)))
    }

    var selectedTextForTesting: String {
        text(in: DOMTreeTextRange(range: selectedTextNSRange)) ?? ""
    }

    func editMenuTitlesForSelectedTextForTesting() -> [String] {
        let suggestedActions = [
            UIAction(title: "Translate") { _ in },
            UIAction(title: "Share...") { _ in },
        ]
        return editMenu(
            for: DOMTreeTextRange(range: selectedTextNSRange),
            suggestedActions: suggestedActions
        )?.children.compactMap { ($0 as? UIAction)?.title } ?? []
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
        return makeDOMMenu(for: [row.node])
    }

    func contextMenuTitlesForTesting(containing text: String) -> [String] {
        contextMenuForTesting(containing: text)?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    func synchronizeDocumentForTesting() {
        reloadTree()
    }

    func selectedRowRectsForTesting() -> [CGRect] {
        selectedContentRowRects()
    }

    var fragmentSubviewCountForTesting: Int {
        textContentView.subviews.filter { $0 is DOMTreeTextLayoutFragmentView }.count
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

    static func disclosureColorForTesting(style: UIUserInterfaceStyle) -> UIColor {
        DOMTreeHighlightTheme.webInspector.disclosure.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
    }
}
#endif

private final class DOMTreeTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

private final class DOMTreeTextRange: UITextRange {
    let range: NSRange

    init(range: NSRange) {
        self.range = range
        super.init()
    }

    override var start: UITextPosition {
        DOMTreeTextPosition(offset: range.location)
    }

    override var end: UITextPosition {
        DOMTreeTextPosition(offset: NSMaxRange(range))
    }

    override var isEmpty: Bool {
        range.length == 0
    }
}

private final class DOMTreeTextSelectionRect: UITextSelectionRect {
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
        disclosure: .systemGray,
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

    static func canContainChildNodes(_ node: DOMNodeModel) -> Bool {
        switch inferredNodeType(for: node) {
        case .document, .documentFragment:
            return true
        case .element:
            return !voidElementNames.contains(elementName(for: node))
        default:
            return false
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

private final class DOMTreeTextContentView: UIView {
    var hoverRowRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }
    var multiSelectedRowRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }
    var selectedRowRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

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
        for rowRect in multiSelectedRowRects where rowRect.intersects(rect) {
            context.fill(rowRect)
        }
        for rowRect in selectedRowRects where rowRect.intersects(rect) {
            context.fill(rowRect)
        }
        context.restoreGState()
    }
}

private final class DOMTreeTextLayoutFragmentView: UIView {
    let layoutFragment: NSTextLayoutFragment
    var layoutFragmentDrawPoint = CGPoint.zero
    var findHighlightRects: [CGRect] = []
    var currentFindHighlightRects: [CGRect] = []

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
