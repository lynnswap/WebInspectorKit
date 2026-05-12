#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class DOMTreeTextView: UIScrollView, @preconcurrency NSTextViewportLayoutControllerDelegate, UITextInput, UITextInteractionDelegate {
    fileprivate static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let lineSpacing: CGFloat = 2
    private static let textInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 16)
    private static let indentSpacesPerDepth = 2
    private static let disclosureSlotSpaces = 2
    private static let characterWidth: CGFloat = {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }()
    private static let disclosureSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
    private static let paragraphLineHeight: CGFloat = {
        ceil(font.lineHeight + lineSpacing)
    }()
    fileprivate static let textBaselineOffset: CGFloat = {
        (paragraphLineHeight - font.lineHeight) / 2
    }()
    fileprivate static let paragraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.minimumLineHeight = paragraphLineHeight
        paragraphStyle.maximumLineHeight = paragraphLineHeight
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        return paragraphStyle
    }()
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
    private var childRequestRetryCounts: [DOMNodeModel.ID: Int] = [:]
    private var findFoundRanges: [NSRange] = []
    private var findHighlightedRanges: [NSRange] = []
    private var hoverRowRects: [CGRect] = []
    private var selectedRowRects: [CGRect] = []
    private var multiSelectedRowRects: [CGRect] = []
    private var findDecorationBatchDepth = 0
    private var pendingFindDecorationInvalidationRanges: [NSRange] = []
    private var measuredTextWidth: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var rowIndexByNodeID: [DOMNodeModel.ID: Int] = [:]
    private var lastObservedSelectedNodeID: DOMNodeModel.ID?
    private var pendingRevealSelectedNodeID: DOMNodeModel.ID?
    private var pendingTreeInvalidation: DOMTreeInvalidation?
    private var scheduledTreeReloadTask: Task<Void, Never>?
    private var treeInvalidationHandlerID: UUID?
    private var lastDocumentReloadSignature: DOMTreeDocumentReloadSignature?
    private var resolvedTextAttributesCache: DOMTreeResolvedTextAttributes?
    private var disclosureSymbolImageCache: [DisclosureSymbolImageCacheKey: UIImage] = [:]
    private var renderedLinePrefixCache: [Int: String] = [:]
    private var markupCache: [DOMNodeModel.ID: DOMTreeCachedMarkup] = [:]
    private var maxLineDisplayColumnCount = 0
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
    private var reloadTreeCallCount = 0
    private var buildRenderedRowsCallCount = 0
    private var rebuildTextStorageCallCount = 0
    private var incrementalTextStorageEditCallCount = 0
    private var resetTextFragmentViewsCallCount = 0
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
        Self.paragraphLineHeight
    }

    init(dom: WIDOMRuntime) {
        self.dom = dom
        super.init(frame: .zero)
        configureTextSystem()
        configureInteractions()
        startObservingDocument()
        reloadTree(resetFragments: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        if let treeInvalidationHandlerID {
            dom.document.removeTreeInvalidationHandler(id: treeInvalidationHandlerID)
        }
        scheduledTreeReloadTask?.cancel()
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
        configureRowBackgrounds(
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
        if isDisclosureHit(at: location, in: row) {
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

        switch style {
        case .normal:
            guard findFoundRanges.contains(clampedRange) || findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
        case .found:
            guard !findFoundRanges.contains(clampedRange) || findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
            findFoundRanges.append(clampedRange)
        case .highlighted:
            guard findFoundRanges.contains(clampedRange) || !findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.append(clampedRange)
        @unknown default:
            guard !findFoundRanges.contains(clampedRange) || findHighlightedRanges.contains(clampedRange) else {
                return
            }
            findFoundRanges.removeAll { $0 == clampedRange }
            findHighlightedRanges.removeAll { $0 == clampedRange }
            findFoundRanges.append(clampedRange)
        }
        invalidateFindDecorationRanges([clampedRange])
    }

    func clearFindDecorations() {
        let previousRanges = findFoundRanges + findHighlightedRanges
        guard !previousRanges.isEmpty else {
            return
        }
        findFoundRanges.removeAll()
        findHighlightedRanges.removeAll()
        invalidateFindDecorationRanges(previousRanges)
    }

    func beginFindDecorationBatch() {
        findDecorationBatchDepth += 1
    }

    func endFindDecorationBatch() {
        guard findDecorationBatchDepth > 0 else {
            return
        }
        findDecorationBatchDepth -= 1
        guard findDecorationBatchDepth == 0 else {
            return
        }

        let ranges = pendingFindDecorationInvalidationRanges
        pendingFindDecorationInvalidationRanges.removeAll(keepingCapacity: true)
        guard !ranges.isEmpty else {
            return
        }
        setNeedsDisplayForTextRanges(ranges)
        updateFindHighlightFragmentViews()
    }

    private func invalidateFindDecorationRanges(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else {
            return
        }

        if findDecorationBatchDepth > 0 {
            pendingFindDecorationInvalidationRanges.append(contentsOf: ranges)
        } else {
            setNeedsDisplayForTextRanges(ranges)
            updateFindHighlightFragmentViews()
        }
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
           isDisclosureHit(at: contentPoint, in: row) {
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
            self.resolvedTextAttributesCache = nil
            self.disclosureSymbolImageCache.removeAll(keepingCapacity: true)
            self.reapplyTextAttributes()
            self.updateDecorations()
        }
    }

    private func startObservingDocument() {
        if let treeInvalidationHandlerID {
            dom.document.removeTreeInvalidationHandler(id: treeInvalidationHandlerID)
        }
        treeInvalidationHandlerID = dom.document.addTreeInvalidationHandler { [weak self] invalidation in
            self?.scheduleTreeReload(for: invalidation)
        }

        lastDocumentReloadSignature = documentReloadSignature()
        dom.document.observe([\.documentState, \.rootNode, \.errorMessage]) { [weak self] in
            guard let self else {
                return
            }
            let signature = self.documentReloadSignature()
            guard signature != self.lastDocumentReloadSignature else {
                return
            }
            self.lastDocumentReloadSignature = signature
            self.scheduleTreeReload(for: .documentReset)
        }
        .store(in: observationScope)

        dom.document.observe([\.selectedNode, \.selectionRevision]) { [weak self] in
            self?.handleSelectedNodeChange()
        }
        .store(in: observationScope)
    }

    private func documentReloadSignature() -> DOMTreeDocumentReloadSignature {
        DOMTreeDocumentReloadSignature(
            documentState: dom.document.documentState,
            rootNodeID: dom.document.rootNode?.id,
            errorMessage: dom.document.errorMessage
        )
    }

    private func handleSelectedNodeChange() {
        let previousOpenState = openState
        prepareSelectionForRendering(clearsMultiSelectionForDocumentSelection: true)
        if previousOpenState != openState || selectedNodeNeedsRowReload() {
            reloadTree(resetFragments: false)
            return
        }
        updateContentDecorations()
        revealPendingSelectedNodeIfPossible()
    }

    private func scheduleTreeReload(for invalidation: DOMTreeInvalidation) {
        if let pending = pendingTreeInvalidation {
            pendingTreeInvalidation = pending.merged(with: invalidation)
        } else {
            pendingTreeInvalidation = invalidation
        }
        guard scheduledTreeReloadTask == nil else {
            return
        }
        scheduledTreeReloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else {
                return
            }
            let invalidation = self.pendingTreeInvalidation
            self.pendingTreeInvalidation = nil
            self.scheduledTreeReloadTask = nil
            self.reloadTree(for: invalidation)
        }
    }

    private func reloadTree(for invalidation: DOMTreeInvalidation?) {
#if DEBUG
        reloadTreeCallCount += 1
#endif
        if case let .content(affectedKeys) = invalidation,
           applyContentInvalidation(affectedKeys: affectedKeys) {
            return
        }
        reloadTree(resetFragments: invalidation?.requiresTextFragmentReset == true, countsCall: false)
    }

    private func reloadTree(resetFragments: Bool, countsCall: Bool = true) {
#if DEBUG
        if countsCall {
            reloadTreeCallCount += 1
        }
#endif
        let previousRows = rows
        let previousText = renderedText
        if resetFragments {
            markupCache.removeAll(keepingCapacity: true)
        }
        prepareSelectionForRendering()
        let buildResult = buildRenderedRows()
        rows = buildResult.rows
        rebuildRowIndexAndPruneMarkupCache()
        reconcileMultiSelectionAfterReload()
        renderedText = buildResult.text
        clampTextSelectionAfterTextChange()
        maxLineDisplayColumnCount = buildResult.maxLineDisplayColumnCount
        updateMeasuredTextWidth()
        pruneChildRequestState()
        requestChildrenForOpenRowsIfNeeded()
        if resetFragments {
            resetTextFragmentViews()
            rebuildTextStorage()
        } else {
            updateTextStorageIncrementally(
                previousRows: previousRows,
                previousText: previousText,
                nextRows: rows,
                nextText: renderedText
            )
        }

        clearFindDecorations()
        findCoordinator.invalidateResultsAfterTextChange()
        updateTextLayoutGeometry()
        updateContentDecorations()
        setNeedsLayout()
        revealPendingSelectedNodeIfPossible()
    }

    private func applyContentInvalidation(affectedKeys: Set<DOMNodeKey>) -> Bool {
        guard dom.document.documentState == .ready, !rows.isEmpty else {
            return false
        }

        let documentIdentity = dom.document.documentIdentity
        let affectedRowIndices = affectedKeys.compactMap {
            rowIndexByNodeID[
                DOMNodeModel.ID(
                    documentIdentity: documentIdentity,
                    targetIdentifier: $0.targetIdentifier,
                    nodeID: $0.nodeID
                )
            ]
        }
        guard !affectedRowIndices.isEmpty else {
            return true
        }
        guard affectedRowIndices.count <= max(8, rows.count / 4) else {
            return false
        }

        var nextRows = rows
        let mutableText = NSMutableString(string: renderedText)
        var replacements: [(range: NSRange, text: String)] = []
        var changedRowIndices = Set<Int>()
        var nextMaxLineDisplayColumnCount = maxLineDisplayColumnCount
        var needsMaxLineDisplayColumnCountRebuild = false

        for rowIndex in affectedRowIndices.sorted(by: >) {
            let previousRow = nextRows[rowIndex]
            let nextRow = renderedRow(
                for: previousRow.node,
                depth: previousRow.depth,
                rowIndex: rowIndex,
                utf16Location: previousRow.textRange.location
            )
            guard !previousRow.hasSameRenderedContent(as: nextRow) else {
                continue
            }

            replacements.append((previousRow.textRange, nextRow.text))
            mutableText.replaceCharacters(in: previousRow.textRange, with: nextRow.text)
            nextRows[rowIndex] = nextRow
            changedRowIndices.insert(rowIndex)
            if nextRow.displayColumnCount > nextMaxLineDisplayColumnCount {
                nextMaxLineDisplayColumnCount = nextRow.displayColumnCount
            } else if previousRow.displayColumnCount == maxLineDisplayColumnCount,
                      nextRow.displayColumnCount < previousRow.displayColumnCount {
                needsMaxLineDisplayColumnCountRebuild = true
            }

            let delta = nextRow.textRange.length - previousRow.textRange.length
            guard delta != 0, rowIndex + 1 < nextRows.count else {
                continue
            }
            for shiftedIndex in (rowIndex + 1)..<nextRows.count {
                nextRows[shiftedIndex] = nextRows[shiftedIndex].offsettingTextRange(by: delta)
            }
        }

        guard !replacements.isEmpty else {
            requestChildrenForOpenRowsIfNeeded()
            updateContentDecorations()
            revealPendingSelectedNodeIfPossible()
            return true
        }

        rows = nextRows
        renderedText = mutableText as String
        clampTextSelectionAfterTextChange()
        maxLineDisplayColumnCount = needsMaxLineDisplayColumnCountRebuild
            ? recomputeMaxLineDisplayColumnCount()
            : nextMaxLineDisplayColumnCount
        updateMeasuredTextWidth()
        pruneChildRequestState()
        requestChildrenForOpenRowsIfNeeded()

        textContentStorage.performEditingTransaction {
            for replacement in replacements {
                textStorage.replaceCharacters(in: replacement.range, with: replacement.text)
            }
        }
#if DEBUG
        incrementalTextStorageEditCallCount += 1
#endif

        let changedRows = changedRowIndices.sorted().map { rows[$0] }
        applyTextAttributes(to: changedRows)
        setNeedsDisplayForTextRanges(changedRows.map(\.textRange))
        clearFindDecorations()
        findCoordinator.invalidateResultsAfterTextChange()
        updateTextLayoutGeometry()
        updateContentDecorations()
        setNeedsLayout()
        revealPendingSelectedNodeIfPossible()
        return true
    }

    private func prepareSelectionForRendering(clearsMultiSelectionForDocumentSelection: Bool = false) {
        let selectedNode = dom.document.selectedNode
        let selectedNodeID = selectedNode?.id
        let selectedNodeIDChanged = selectedNodeID != lastObservedSelectedNodeID
        if selectedNodeIDChanged {
            lastObservedSelectedNodeID = selectedNodeID
            pendingRevealSelectedNodeID = selectedNodeID
        }
        reconcileMultiSelectionForRenderedSelection(
            selectedNodeID: selectedNodeID,
            selectedNodeIDChanged: selectedNodeIDChanged,
            clearsMultiSelectionForDocumentSelection: clearsMultiSelectionForDocumentSelection
        )

        guard let selectedNode else {
            pendingRevealSelectedNodeID = nil
            return
        }
        openAncestors(of: selectedNode)
    }

    private func reconcileMultiSelectionForRenderedSelection(
        selectedNodeID: DOMNodeModel.ID?,
        selectedNodeIDChanged: Bool,
        clearsMultiSelectionForDocumentSelection: Bool
    ) {
        if clearsMultiSelectionForDocumentSelection {
            if let selectedNodeID {
                if !multiSelectedNodeIDs.isEmpty
                    || multiSelectionLastNodeID != selectedNodeID
                    || multiSelectionShiftAnchorNodeID != nil
                    || !multiSelectionShiftRangeNodeIDs.isEmpty {
                    clearMultiSelection(keepingLast: selectedNodeID)
                }
            } else if !multiSelectedNodeIDs.isEmpty
                        || multiSelectionLastNodeID != nil
                        || multiSelectionShiftAnchorNodeID != nil
                        || !multiSelectionShiftRangeNodeIDs.isEmpty {
                clearMultiSelection(keepingLast: nil)
            }
            return
        }

        guard selectedNodeIDChanged else {
            return
        }
        if let selectedNodeID, !multiSelectedNodeIDs.contains(selectedNodeID) {
            clearMultiSelection(keepingLast: selectedNodeID)
        } else if selectedNodeID == nil {
            clearMultiSelection(keepingLast: nil)
        }
    }

    private func openAncestors(of node: DOMNodeModel) {
        var current = node.parent
        while let ancestor = current {
            if ancestor.nodeType != .document || ancestor.parent != nil {
                openState[ancestor.id] = true
            }
            current = ancestor.parent
        }
    }

    private func buildRenderedRows() -> (rows: [DOMTreeLine], text: String, maxLineDisplayColumnCount: Int) {
#if DEBUG
        buildRenderedRowsCallCount += 1
#endif
        guard dom.document.documentState == .ready else {
            return ([], "", 0)
        }
        guard let rootNode = dom.document.rootNode else {
            return ([], "", 0)
        }

        var nextRows: [DOMTreeLine] = []
        nextRows.reserveCapacity(rows.count)
        var nextText = ""
        nextText.reserveCapacity(renderedText.count)
        var utf16Location = 0
        var maxLineDisplayColumnCount = 0

        func appendLine(_ node: DOMNodeModel, depth: Int, isClosingTag: Bool) -> DOMTreeLine {
            let rowIndex = nextRows.count
            let row = renderedRow(
                for: node,
                depth: depth,
                rowIndex: rowIndex,
                utf16Location: utf16Location,
                isClosingTag: isClosingTag
            )

            maxLineDisplayColumnCount = max(maxLineDisplayColumnCount, row.displayColumnCount)
            nextRows.append(row)
            if rowIndex > 0 {
                nextText.append("\n")
            }
            nextText.append(row.text)
            utf16Location += row.textRange.length + 1
            return row
        }

        func append(_ node: DOMNodeModel, depth: Int) {
            let row = appendLine(node, depth: depth, isClosingTag: false)
            guard row.hasDisclosure, row.isOpen else {
                return
            }
            for child in node.visibleDOMTreeChildren {
                append(child, depth: depth + 1)
            }
            if DOMTreeMarkupBuilder.rendersClosingTagRow(for: node) {
                _ = appendLine(node, depth: depth, isClosingTag: true)
            }
        }

        let displayRoots = rootNode.nodeType == .document ? rootNode.visibleDOMTreeChildren : [rootNode]
        for node in displayRoots {
            append(node, depth: 0)
        }

        return (nextRows, nextText, maxLineDisplayColumnCount)
    }

    private func renderedRow(
        for node: DOMNodeModel,
        depth: Int,
        rowIndex: Int,
        utf16Location: Int,
        isClosingTag: Bool = false
    ) -> DOMTreeLine {
        let hasDisclosure = !isClosingTag && nodeHasDisclosure(node)
        let isOpen = !isClosingTag && isNodeOpen(node, depth: depth)
        let markup = cachedMarkup(
            for: node,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag
        )
        let prefix = renderedLinePrefix(depth: depth)
        let line = prefix + markup.text
        let prefixLength = depth * Self.indentSpacesPerDepth + Self.disclosureSlotSpaces
        let lineLength = prefixLength + markup.utf16Length
        var tokens: [DOMTreeToken] = []
        tokens.reserveCapacity(markup.tokens.count)
        for token in markup.tokens {
            tokens.append(
                DOMTreeToken(
                    kind: token.kind,
                    range: NSRange(location: prefixLength + token.range.location, length: token.range.length)
                )
            )
        }

        return DOMTreeLine(
            node: node,
            depth: depth,
            rowIndex: rowIndex,
            text: line,
            textRange: NSRange(location: utf16Location, length: lineLength),
            markupRange: NSRange(location: prefixLength, length: markup.utf16Length),
            tokens: tokens,
            displayColumnCount: prefixLength + markup.displayColumnCount,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag
        )
    }

    private func cachedMarkup(
        for node: DOMNodeModel,
        hasDisclosure: Bool,
        isOpen: Bool,
        isClosingTag: Bool
    ) -> DOMTreeMarkup {
        let signature = DOMTreeMarkupSignature(
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType,
            isTemplateContent: node.parent?.templateContent === node,
            attributes: node.attributes,
            childCount: node.regularChildCount,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag
        )
        if let cached = markupCache[node.id],
           cached.signature == signature {
            return cached.markup
        }
        let markup = DOMTreeMarkupBuilder.markup(
            for: node,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag
        )
        markupCache[node.id] = DOMTreeCachedMarkup(signature: signature, markup: markup)
        return markup
    }

    private func pruneMarkupCache(keeping nodeIDs: Set<DOMNodeModel.ID>) {
        markupCache = markupCache.filter { nodeIDs.contains($0.key) }
    }

    private func nodeHasDisclosure(_ node: DOMNodeModel) -> Bool {
        node.hasVisibleDOMTreeChildren
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
        if let cached = renderedLinePrefixCache[depth] {
            return cached
        }
        let prefix = String(repeating: " ", count: depth * Self.indentSpacesPerDepth + Self.disclosureSlotSpaces)
        renderedLinePrefixCache[depth] = prefix
        return prefix
    }

    private func rebuildRowIndexAndPruneMarkupCache() {
        var nextRowIndexByNodeID: [DOMNodeModel.ID: Int] = [:]
        nextRowIndexByNodeID.reserveCapacity(rows.count)
        var visibleNodeIDs = Set<DOMNodeModel.ID>()
        visibleNodeIDs.reserveCapacity(rows.count)
        for row in rows {
            if !row.isClosingTag, nextRowIndexByNodeID[row.node.id] == nil {
                nextRowIndexByNodeID[row.node.id] = row.rowIndex
            }
            visibleNodeIDs.insert(row.node.id)
        }
        rowIndexByNodeID = nextRowIndexByNodeID
        pruneMarkupCache(keeping: visibleNodeIDs)
    }

    private func recomputeMaxLineDisplayColumnCount() -> Int {
        var maxColumnCount = 0
        for row in rows where row.displayColumnCount > maxColumnCount {
            maxColumnCount = row.displayColumnCount
        }
        return maxColumnCount
    }

    private func updateMeasuredTextWidth() {
        measuredTextWidth = CGFloat(maxLineDisplayColumnCount) * Self.characterWidth
    }

    private func pruneChildRequestState() {
        requestedChildNodeIDs = requestedChildNodeIDs.filter { nodeID in
            guard let node = dom.document.node(id: nodeID) else {
                return false
            }
            return node.hasUnloadedRegularChildren
        }
        childRequestRetryCounts = childRequestRetryCounts.filter { nodeID, _ in
            guard let node = dom.document.node(id: nodeID) else {
                return false
            }
            return node.hasUnloadedRegularChildren
        }
    }

    private func requestChildrenForOpenRowsIfNeeded() {
        guard dom.document.documentState == .ready else {
            return
        }
        for row in rows where row.hasDisclosure && row.isOpen {
            requestChildrenIfNeeded(for: row.node)
        }
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
        guard node.hasUnloadedRegularChildren,
              requestedChildNodeIDs.insert(node.id).inserted
        else {
            return
        }
        let attempt = childRequestRetryCounts[node.id, default: 0] + 1
        childRequestRetryCounts[node.id] = attempt
        Task { @MainActor [weak self, weak node] in
            guard let self, let node else {
                return
            }
            let succeeded = await self.dom.requestChildNodes(for: node, depth: 3)
            self.requestedChildNodeIDs.remove(node.id)
            guard self.dom.document.node(id: node.id) === node else {
                self.childRequestRetryCounts.removeValue(forKey: node.id)
                return
            }
            if succeeded || !node.hasUnloadedRegularChildren {
                self.childRequestRetryCounts.removeValue(forKey: node.id)
                return
            }
            guard attempt < 3 else {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else {
                return
            }
            self.requestChildrenIfNeeded(for: node)
        }
    }

    private func toggle(row: DOMTreeLine) {
        openState[row.node.id] = !row.isOpen
        reloadTree(resetFragments: false)
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
            !row.isClosingTag && multiSelectedNodeIDs.contains(row.node.id) ? row.node : nil
        }
    }

    private func scrollRowToVisible(_ row: DOMTreeLine) {
        guard let rowRect = contentRowRects(for: row).first else {
            return
        }
        let headRect = rowHeadRect(for: row) ?? rowRect
        let targetRect = CGRect(
            x: Self.textInsets.left + headRect.minX,
            y: Self.textInsets.top + rowRect.minY,
            width: max(1, headRect.width),
            height: rowRect.height
        )
        scrollRectToVisible(targetRect.insetBy(dx: 0, dy: -rowRect.height), animated: true)
    }

    private func row(at location: CGPoint) -> DOMTreeLine? {
        guard location.y >= 0,
              let textRange = lineFragmentTextRange(at: location),
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
        resolvedTextAttributes().base
    }

    private func resolvedTextAttributes() -> DOMTreeResolvedTextAttributes {
        let style = traitCollection.userInterfaceStyle
        if let cached = resolvedTextAttributesCache,
           cached.userInterfaceStyle == style {
            return cached
        }
        let resolved = DOMTreeResolvedTextAttributes(traitCollection: traitCollection)
        resolvedTextAttributesCache = resolved
        return resolved
    }

    private func reapplyTextAttributes() {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else {
            return
        }
        textStorage.addAttributes(baseTextAttributes(), range: fullRange)
        applyRowAttributes(to: textStorage)
        applyDisclosureAttachments(to: textStorage, rows: rows)
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
        applyDisclosureAttachments(to: attributedText, rows: rows)
#if DEBUG
        rebuildTextStorageCallCount += 1
#endif
        textContentStorage.performEditingTransaction {
            textStorage.setAttributedString(attributedText)
        }
        invalidateTextLayout()
    }

    private func updateTextStorageIncrementally(
        previousRows: [DOMTreeLine],
        previousText: String,
        nextRows: [DOMTreeLine],
        nextText: String
    ) {
        guard !previousText.isEmpty, !nextText.isEmpty else {
            rebuildTextStorage()
            return
        }
        guard let diff = rowDiff(previousRows: previousRows, nextRows: nextRows) else {
            return
        }

        let edit = textEdit(
            previousRows: previousRows,
            previousText: previousText,
            nextRows: nextRows,
            diff: diff
        )
        textContentStorage.performEditingTransaction {
            textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
#if DEBUG
        incrementalTextStorageEditCallCount += 1
#endif

        let changedRows = Array(nextRows[diff.nextStart..<diff.nextEnd])
        applyTextAttributes(to: changedRows)
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            setNeedsDisplayForTextRanges(changedRows.map(\.textRange))
        }
    }

    private func rowDiff(
        previousRows: [DOMTreeLine],
        nextRows: [DOMTreeLine]
    ) -> DOMTreeRowDiff? {
        var prefix = 0
        while prefix < previousRows.count,
              prefix < nextRows.count,
              previousRows[prefix].hasSameRenderedContent(as: nextRows[prefix]) {
            prefix += 1
        }

        var previousSuffix = previousRows.count
        var nextSuffix = nextRows.count
        while previousSuffix > prefix,
              nextSuffix > prefix,
              previousRows[previousSuffix - 1].hasSameRenderedContent(as: nextRows[nextSuffix - 1]) {
            previousSuffix -= 1
            nextSuffix -= 1
        }

        guard prefix != previousRows.count || prefix != nextRows.count else {
            return nil
        }
        return DOMTreeRowDiff(
            previousStart: prefix,
            previousEnd: previousSuffix,
            nextStart: prefix,
            nextEnd: nextSuffix
        )
    }

    private func textEdit(
        previousRows: [DOMTreeLine],
        previousText: String,
        nextRows: [DOMTreeLine],
        diff: DOMTreeRowDiff
    ) -> (range: NSRange, replacement: String) {
        let previousLength = (previousText as NSString).length
        let location: Int
        let length: Int
        if diff.previousStart == 0 {
            location = 0
            if diff.previousEnd == previousRows.count {
                length = previousLength
            } else {
                length = previousRows[diff.previousEnd].textRange.location
            }
        } else {
            let previousRow = previousRows[diff.previousStart - 1]
            location = previousRow.textRange.location + previousRow.textRange.length
            if diff.previousEnd == previousRows.count {
                length = previousLength - location
            } else {
                length = previousRows[diff.previousEnd].textRange.location - location
            }
        }

        let replacementRows = nextRows[diff.nextStart..<diff.nextEnd].map(\.text).joined(separator: "\n")
        let replacement: String
        if diff.nextStart == 0 {
            replacement = replacementRows + (diff.nextEnd < nextRows.count && !replacementRows.isEmpty ? "\n" : "")
        } else if replacementRows.isEmpty {
            replacement = diff.nextEnd < nextRows.count ? "\n" : ""
        } else {
            replacement = "\n" + replacementRows + (diff.nextEnd < nextRows.count ? "\n" : "")
        }
        return (NSRange(location: location, length: length), replacement)
    }

    private func applyTextAttributes(to rows: [DOMTreeLine]) {
        guard !rows.isEmpty else {
            return
        }
        for row in rows {
            guard row.textRange.location + row.textRange.length <= textStorage.length else {
                continue
            }
            textStorage.addAttributes(baseTextAttributes(), range: row.textRange)
            applySyntaxAttributes(for: row, to: textStorage)
        }
        applyDisclosureAttachments(to: textStorage, rows: rows)
    }

    private func applySyntaxAttributes(for row: DOMTreeLine, to attributedText: NSMutableAttributedString) {
        let colors = resolvedTextAttributes().tokenColors
        attributedText.addAttribute(
            .foregroundColor,
            value: colors[.fallback] ?? DOMTreeHighlightTheme.webInspector.textSecondary.resolvedColor(with: traitCollection),
            range: row.textRange
        )
        for token in row.tokens {
            attributedText.addAttribute(
                .foregroundColor,
                value: colors[token.kind] ?? DOMTreeHighlightTheme.webInspector.textSecondary.resolvedColor(with: traitCollection),
                range: NSRange(location: row.textRange.location + token.range.location, length: token.range.length)
            )
        }
    }

    private func applyDisclosureAttachments(to attributedText: NSMutableAttributedString, rows: [DOMTreeLine]) {
        for row in rows where row.hasDisclosure {
            let range = disclosureAttachmentRange(for: row)
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
        var attributes = baseTextAttributes()
        let disclosureColor = DOMTreeHighlightTheme.webInspector.disclosure.resolvedColor(with: traitCollection)
        attributes[.foregroundColor] = disclosureColor

        guard let image = disclosureSymbolImage(isOpen: isOpen, color: disclosureColor) else {
            return NSAttributedString(string: isOpen ? "v" : ">", attributes: attributes)
        }

        let attachment = NSTextAttachment(image: image)
        attachment.bounds = Self.disclosureAttachmentBounds(for: image)
        let attributedString = NSMutableAttributedString(attachment: attachment)
        attributedString.addAttributes(attributes, range: NSRange(location: 0, length: attributedString.length))
        return attributedString
    }

    private func disclosureSymbolImage(isOpen: Bool, color: UIColor) -> UIImage? {
        let key = DisclosureSymbolImageCacheKey(userInterfaceStyle: traitCollection.userInterfaceStyle, isOpen: isOpen)
        if let cached = disclosureSymbolImageCache[key] {
            return cached
        }
        guard let image = Self.rotatedDisclosureTriangleImage(isOpen: isOpen, color: color) else {
            return nil
        }
        disclosureSymbolImageCache[key] = image
        return image
    }

    private static func rotatedDisclosureTriangleImage(isOpen: Bool, color: UIColor) -> UIImage? {
        guard let image = UIImage(
            systemName: "triangle.fill",
            withConfiguration: disclosureSymbolConfiguration
        )?.withTintColor(color, renderingMode: .alwaysOriginal) else {
            return nil
        }
        return rotatedImage(image, radians: isOpen ? .pi : .pi / 2)
    }

    private static func rotatedImage(_ image: UIImage, radians: CGFloat) -> UIImage {
        let sourceSize = image.size
        let rotatedBounds = CGRect(origin: .zero, size: sourceSize)
            .applying(CGAffineTransform(rotationAngle: radians))
            .standardized
        let targetSize = CGSize(width: ceil(rotatedBounds.width), height: ceil(rotatedBounds.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            context.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
            context.rotate(by: radians)
            image.draw(in: CGRect(
                x: -sourceSize.width / 2,
                y: -sourceSize.height / 2,
                width: sourceSize.width,
                height: sourceSize.height
            ))
        }
    }

    private static func disclosureAttachmentBounds(for image: UIImage) -> CGRect {
        CGRect(
            x: 0,
            y: (font.capHeight - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
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
#if DEBUG
        resetTextFragmentViewsCallCount += 1
#endif
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

    private func configureHighlights(
        for fragmentView: DOMTreeTextLayoutFragmentView,
        surfaceFrame: CGRect
    ) {
        let foundRects: [CGRect]
        let highlightedRects: [CGRect]
        if findFoundRanges.isEmpty && findHighlightedRanges.isEmpty {
            foundRects = []
            highlightedRects = []
        } else {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            foundRects = textRects(
                in: surfaceFrame,
                ranges: Self.ranges(findFoundRanges, intersecting: fragmentRange)
            )
            highlightedRects = textRects(
                in: surfaceFrame,
                ranges: Self.ranges(findHighlightedRanges, intersecting: fragmentRange)
            )
        }
        let foundColor = foundRects.isEmpty
            ? nil
            : DOMTreeHighlightTheme.webInspector.findBackground.resolvedColor(with: traitCollection).cgColor
        let highlightedColor = highlightedRects.isEmpty
            ? nil
            : DOMTreeHighlightTheme.webInspector.currentFindBackground.resolvedColor(with: traitCollection).cgColor
        let foundChanged = fragmentView.findHighlightRects != foundRects
            || !Self.optionalColorsEqual(fragmentView.findHighlightColor, foundColor)
        let highlightedChanged = fragmentView.currentFindHighlightRects != highlightedRects
            || !Self.optionalColorsEqual(fragmentView.currentFindHighlightColor, highlightedColor)

        fragmentView.findHighlightRects = foundRects
        fragmentView.findHighlightColor = foundColor
        fragmentView.currentFindHighlightRects = highlightedRects
        fragmentView.currentFindHighlightColor = highlightedColor
        if foundChanged || highlightedChanged {
            fragmentView.setNeedsDisplay()
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

    private func selectedNodeNeedsRowReload() -> Bool {
        guard let selectedNodeID = dom.document.selectedNode?.id else {
            return false
        }
        return rowIndexByNodeID[selectedNodeID] == nil
    }

    private func multiSelectionContentRowRects() -> [CGRect] {
        rows.flatMap { row in
            !row.isClosingTag && multiSelectedNodeIDs.contains(row.node.id) ? contentRowRects(for: row) : []
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
        return contentRowRects(for: rows[rowIndex])
    }

    private func contentRowRects(for row: DOMTreeLine) -> [CGRect] {
        textSegmentRects(for: row.textRange, type: .highlight).map { textRect in
            CGRect(
                x: 0,
                y: textRect.minY,
                width: max(textContentView.bounds.width, contentSize.width - Self.textInsets.left - Self.textInsets.right),
                height: textRect.height
            )
        }
    }

    private func rowHeadRect(for row: DOMTreeLine) -> CGRect? {
        if row.hasDisclosure {
            return disclosureHitRect(for: row)
        }
        return markupStartRect(for: row) ?? contentRowRects(for: row).first
    }

    private func markupStartRect(for row: DOMTreeLine) -> CGRect? {
        let markupStart = row.textRange.location + row.markupRange.location
        let markupLength = min(1, row.markupRange.length)
        guard markupLength > 0 else {
            return nil
        }
        return unionRect(textSegmentRects(
            for: NSRange(location: markupStart, length: markupLength),
            type: .standard
        ))
    }

    private func isDisclosureHit(at point: CGPoint, in row: DOMTreeLine) -> Bool {
        guard let hitRect = disclosureHitRect(for: row) else {
            return false
        }
        return hitRect.contains(point)
    }

    private func disclosureHitRect(for row: DOMTreeLine) -> CGRect? {
        guard row.hasDisclosure else {
            return nil
        }
        guard let slotRect = unionRect(textSegmentRects(for: disclosureSlotRange(for: row), type: .standard)) else {
            return nil
        }
        guard let rowRect = contentRowRects(for: row).first else {
            return slotRect
        }
        return CGRect(
            x: slotRect.minX,
            y: rowRect.minY,
            width: max(slotRect.width, Self.characterWidth),
            height: rowRect.height
        )
    }

    private func disclosureAttachmentRange(for row: DOMTreeLine) -> NSRange {
        NSRange(location: row.textRange.location + row.depth * Self.indentSpacesPerDepth, length: 1)
    }

    private func disclosureSlotRange(for row: DOMTreeLine) -> NSRange {
        NSRange(
            location: row.textRange.location + row.depth * Self.indentSpacesPerDepth,
            length: Self.disclosureSlotSpaces
        )
    }

    private func unionRect(_ rects: [CGRect]) -> CGRect? {
        var result = CGRect.null
        for rect in rects {
            result = result.union(rect)
        }
        return result.isNull ? nil : result
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

    private func textRects(in layoutFragmentFrame: CGRect, ranges: [NSRange]) -> [CGRect] {
        guard !ranges.isEmpty else {
            return []
        }

        var rects: [CGRect] = []
        let fragmentLocalBounds = CGRect(origin: .zero, size: layoutFragmentFrame.size)
        for range in ranges {
            for rect in textSegmentRects(for: range, type: .standard) {
                let localRect = rect.offsetBy(dx: -layoutFragmentFrame.minX, dy: -layoutFragmentFrame.minY)
                guard localRect.intersects(fragmentLocalBounds) else {
                    continue
                }
                rects.append(localRect)
            }
        }
        return rects
    }

    private func localRowRects(in layoutFragmentFrame: CGRect, contentRects: [CGRect]) -> [CGRect] {
        guard !contentRects.isEmpty else {
            return []
        }

        var rects: [CGRect] = []
        let fragmentLocalBounds = CGRect(origin: .zero, size: layoutFragmentFrame.size)
        for rowRect in contentRects {
            let localRect = rowRect.offsetBy(dx: -layoutFragmentFrame.minX, dy: -layoutFragmentFrame.minY)
            guard localRect.intersects(fragmentLocalBounds) else {
                continue
            }
            let clippedRect = localRect.intersection(fragmentLocalBounds)
            guard !clippedRect.isNull, clippedRect.width > 0, clippedRect.height > 0 else {
                continue
            }
            rects.append(clippedRect)
        }
        return rects
    }

    private func textRange(for layoutFragment: NSTextLayoutFragment) -> NSRange {
        let fragmentStart = textOffset(for: layoutFragment.rangeInElement.location) ?? 0
        let fragmentEnd = textOffset(for: layoutFragment.rangeInElement.endLocation) ?? fragmentStart
        return NSRange(location: fragmentStart, length: max(0, fragmentEnd - fragmentStart))
    }

    private static func ranges(_ ranges: [NSRange], intersecting fragmentRange: NSRange) -> [NSRange] {
        guard !ranges.isEmpty, fragmentRange.length > 0 else {
            return []
        }
        return ranges.compactMap { range in
            let intersection = NSIntersectionRange(range, fragmentRange)
            return intersection.length > 0 ? intersection : nil
        }
    }

    private static func optionalColorsEqual(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return CFEqual(lhs, rhs)
        default:
            return false
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

    private func updateDecorations() {
        updateContentDecorations()
        updateFindHighlightFragmentViews()
    }

    private func updateContentDecorations() {
        hoverRowRects = hoverContentRowRects()
        selectedRowRects = selectedContentRowRects()
        multiSelectedRowRects = multiSelectionContentRowRects()
        updateRowBackgroundFragmentViews()
    }

    private func updateRowBackgroundFragmentViews() {
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            configureRowBackgrounds(
                for: fragmentView,
                surfaceFrame: fragmentView.frame
            )
        }
    }

    private func updateFindHighlightFragmentViews() {
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            configureHighlights(
                for: fragmentView,
                surfaceFrame: fragmentView.frame
            )
        }
    }

    private func configureRowBackgrounds(
        for fragmentView: DOMTreeTextLayoutFragmentView,
        surfaceFrame: CGRect
    ) {
        let hoverRects = localRowRects(in: surfaceFrame, contentRects: hoverRowRects)
        let selectedRects = localRowRects(in: surfaceFrame, contentRects: selectedRowRects)
        let multiSelectedRects = localRowRects(in: surfaceFrame, contentRects: multiSelectedRowRects)
        let hoverColor = hoverRects.isEmpty
            ? nil
            : DOMTreeHighlightTheme.webInspector.hoverRowBackground.resolvedColor(with: traitCollection).cgColor
        let selectedColor = selectedRects.isEmpty && multiSelectedRects.isEmpty
            ? nil
            : DOMTreeHighlightTheme.webInspector.selectedRowBackground.resolvedColor(with: traitCollection).cgColor
        let changed = fragmentView.hoverRowRects != hoverRects
            || !Self.optionalColorsEqual(fragmentView.hoverRowColor, hoverColor)
            || fragmentView.selectedRowRects != selectedRects
            || fragmentView.multiSelectedRowRects != multiSelectedRects
            || !Self.optionalColorsEqual(fragmentView.selectedRowColor, selectedColor)

        fragmentView.hoverRowRects = hoverRects
        fragmentView.hoverRowColor = hoverColor
        fragmentView.selectedRowRects = selectedRects
        fragmentView.multiSelectedRowRects = multiSelectedRects
        fragmentView.selectedRowColor = selectedColor
        if changed {
            fragmentView.setNeedsDisplay()
        }
    }

    private func setNeedsDisplayForTextRanges(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else {
            return
        }

        var invalidatedRect = CGRect.null
        for range in ranges {
            let rects = textSegmentRects(for: range, type: .standard)
            for rect in rects {
                invalidatedRect = invalidatedRect.union(rect)
            }
        }

        if invalidatedRect.isNull {
            setNeedsDisplayForVisibleTextFragments()
        } else {
            invalidateTextFragmentViews(intersecting: invalidatedRect.insetBy(dx: -2, dy: -2))
        }
    }

    private func setNeedsDisplayForVisibleTextFragments() {
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            fragmentView.setNeedsDisplay()
        }
    }

    private func invalidateTextFragmentViews(intersecting rect: CGRect) {
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            guard fragmentView.frame.intersects(rect) else {
                continue
            }
            fragmentView.setNeedsDisplay(rect.offsetBy(dx: -fragmentView.frame.minX, dy: -fragmentView.frame.minY))
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
        guard let rowRect = contentRowRects(for: row).first else {
            return
        }
        let headRect = rowHeadRect(for: row) ?? rowRect
        let targetRect = CGRect(
            x: max(0, Self.textInsets.left + headRect.minX - 12),
            y: Self.textInsets.top + rowRect.minY,
            width: max(1, headRect.width),
            height: rowRect.height
        )
        scrollRectToVisible(
            targetRect.insetBy(dx: 0, dy: -rowRect.height * 2),
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
        let hasDisclosure: Bool
        let isOpen: Bool
        let isClosingTag: Bool
        let tokenKinds: [String]
        let tokenTexts: [String]
    }

    struct DisclosureAttachmentSnapshot {
        let text: String
        let hasAttachment: Bool
        let attachmentRange: NSRange
        let slotRect: CGRect
        let rowRect: CGRect
        let markupStartX: CGFloat
        let isOpen: Bool
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
                markupStartX: markupStartRect(for: row)?.minX ?? 0,
                hasDisclosure: row.hasDisclosure,
                isOpen: row.isOpen,
                isClosingTag: row.isClosingTag,
                tokenKinds: row.tokens.map(\.kind.rawValue),
                tokenTexts: row.tokens.map { line.substring(with: $0.range) }
            )
        }
    }

    func removeRowIndexForTesting(containing text: String) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        rowIndexByNodeID.removeValue(forKey: row.node.id)
    }

    var disclosureAttachmentSnapshotsForTesting: [DisclosureAttachmentSnapshot] {
        rows.compactMap { row in
            guard row.hasDisclosure,
                  let slotRect = disclosureHitRect(for: row),
                  let rowRect = contentRowRects(for: row).first
            else {
                return nil
            }
            let attachmentRange = disclosureAttachmentRange(for: row)
            let hasAttachment = unsafe textStorage.attribute(
                .attachment,
                at: attachmentRange.location,
                effectiveRange: nil
            ) is NSTextAttachment
            return DisclosureAttachmentSnapshot(
                text: row.text,
                hasAttachment: hasAttachment,
                attachmentRange: attachmentRange,
                slotRect: slotRect,
                rowRect: rowRect,
                markupStartX: markupStartRect(for: row)?.minX ?? .greatestFiniteMagnitude,
                isOpen: row.isOpen
            )
        }
    }

    var reloadTreeCallCountForTesting: Int {
        reloadTreeCallCount
    }

    var buildRenderedRowsCallCountForTesting: Int {
        buildRenderedRowsCallCount
    }

    var rebuildTextStorageCallCountForTesting: Int {
        rebuildTextStorageCallCount
    }

    var incrementalTextStorageEditCallCountForTesting: Int {
        incrementalTextStorageEditCallCount
    }

    var resetTextFragmentViewsCallCountForTesting: Int {
        resetTextFragmentViewsCallCount
    }

    func resetPerformanceCountersForTesting() {
        reloadTreeCallCount = 0
        buildRenderedRowsCallCount = 0
        rebuildTextStorageCallCount = 0
        incrementalTextStorageEditCallCount = 0
        resetTextFragmentViewsCallCount = 0
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

    var multiSelectedNodeIDsForTesting: [UInt64] {
        rows.compactMap { row in
            !row.isClosingTag && multiSelectedNodeIDs.contains(row.node.id) ? UInt64(row.node.nodeID) : nil
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

    func decorateStaleFindTextForTesting(query: String) {
        findCoordinator.decorateStaleFoundTextForTesting(queryString: query)
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
        reloadTree(resetFragments: true)
    }

    func selectedRowRectsForTesting() -> [CGRect] {
        selectedContentRowRects()
    }

    var drawnSelectedRowRectsForTesting: [CGRect] {
        selectedRowRects
    }

    func clearDrawnSelectedRowRectsForTesting() {
        selectedRowRects = []
        updateRowBackgroundFragmentViews()
    }

    var fragmentSubviewCountForTesting: Int {
        textContentView.subviews.filter { $0 is DOMTreeTextLayoutFragmentView }.count
    }

    var rowHeightForTesting: CGFloat {
        rowHeight
    }

    var paragraphLineHeightForTesting: CGFloat {
        Self.paragraphLineHeight
    }

    var textBaselineOffsetForTesting: CGFloat {
        Self.textBaselineOffset
    }

    func textHighlightRectsForTesting(containing text: String) -> [CGRect] {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return []
        }
        return textSegmentRects(for: row.textRange, type: .highlight)
    }

    func hitTestedLineTextForTesting(atContentPoint point: CGPoint) -> String? {
        row(at: point)?.text
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

@MainActor
private struct DOMTreeLine {
    let node: DOMNodeModel
    let depth: Int
    let rowIndex: Int
    let text: String
    let textRange: NSRange
    let markupRange: NSRange
    let tokens: [DOMTreeToken]
    let displayColumnCount: Int
    let hasDisclosure: Bool
    let isOpen: Bool
    let isClosingTag: Bool

    func hasSameRenderedContent(as other: DOMTreeLine) -> Bool {
        node.id == other.node.id
            && depth == other.depth
            && text == other.text
            && tokens == other.tokens
            && displayColumnCount == other.displayColumnCount
            && hasDisclosure == other.hasDisclosure
            && isOpen == other.isOpen
            && isClosingTag == other.isClosingTag
    }

    func offsettingTextRange(by delta: Int) -> DOMTreeLine {
        DOMTreeLine(
            node: node,
            depth: depth,
            rowIndex: rowIndex,
            text: text,
            textRange: NSRange(location: textRange.location + delta, length: textRange.length),
            markupRange: markupRange,
            tokens: tokens,
            displayColumnCount: displayColumnCount,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag
        )
    }
}

private struct DOMTreeToken: Equatable {
    let kind: DOMTreeTokenKind
    let range: NSRange
}

private struct DOMTreeRowDiff {
    let previousStart: Int
    let previousEnd: Int
    let nextStart: Int
    let nextEnd: Int
}

private struct DOMTreeDocumentReloadSignature: Equatable {
    let documentState: DOMDocumentState
    let rootNodeID: DOMNodeModel.ID?
    let errorMessage: String?
}

private struct DOMTreeMarkupSignature: Hashable {
    let nodeType: DOMNodeType
    let nodeName: String
    let localName: String
    let nodeValue: String
    let pseudoType: String?
    let shadowRootType: String?
    let isTemplateContent: Bool
    let attributes: [DOMAttribute]
    let childCount: Int
    let hasDisclosure: Bool
    let isOpen: Bool
    let isClosingTag: Bool
}

private struct DOMTreeCachedMarkup {
    let signature: DOMTreeMarkupSignature
    let markup: DOMTreeMarkup
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

@MainActor
private struct DOMTreeResolvedTextAttributes {
    let userInterfaceStyle: UIUserInterfaceStyle
    let base: [NSAttributedString.Key: Any]
    let tokenColors: [DOMTreeTokenKind: UIColor]

    init(traitCollection: UITraitCollection) {
        userInterfaceStyle = traitCollection.userInterfaceStyle
        let theme = DOMTreeHighlightTheme.webInspector
        base = [
            .font: DOMTreeTextView.font,
            .paragraphStyle: DOMTreeTextView.paragraphStyle,
            .baselineOffset: DOMTreeTextView.textBaselineOffset,
            .foregroundColor: theme.baseForeground.resolvedColor(with: traitCollection)
        ]
        tokenColors = [
            .punctuation: theme.tagPunctuation.resolvedColor(with: traitCollection),
            .tagName: theme.nodeName.resolvedColor(with: traitCollection),
            .attributeName: theme.nodeAttribute.resolvedColor(with: traitCollection),
            .attributeValue: theme.nodeValue.resolvedColor(with: traitCollection),
            .text: theme.textSecondary.resolvedColor(with: traitCollection),
            .comment: theme.textSecondary.resolvedColor(with: traitCollection),
            .doctype: theme.nodeAttribute.resolvedColor(with: traitCollection),
            .fallback: theme.textSecondary.resolvedColor(with: traitCollection)
        ]
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
    private(set) var utf16Length = 0
    private(set) var displayColumnCount = 0
    private(set) var tokens: [DOMTreeToken] = []

    mutating func append(_ fragment: String, kind: DOMTreeTokenKind) {
        guard !fragment.isEmpty else {
            return
        }
        let metrics = domTreeTextMetrics(for: fragment)
        let start = utf16Length
        text += fragment
        utf16Length += metrics.utf16Length
        displayColumnCount += metrics.displayColumnCount
        tokens.append(
            DOMTreeToken(
                kind: kind,
                range: NSRange(location: start, length: metrics.utf16Length)
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

private struct DOMTreeTextMetrics {
    let utf16Length: Int
    let displayColumnCount: Int
}

private func domTreeTextMetrics(for string: String) -> DOMTreeTextMetrics {
    var utf8Length = 0
    var asciiColumnCount = 0
    var isASCII = true

    for byte in string.utf8 {
        utf8Length += 1
        if byte < 0x80 {
            asciiColumnCount += domTreeASCIIColumnCount(for: byte)
        } else {
            isASCII = false
            break
        }
    }

    if isASCII {
        return DOMTreeTextMetrics(
            utf16Length: utf8Length,
            displayColumnCount: asciiColumnCount
        )
    }

    var utf16Length = 0
    var displayColumnCount = 0
    for scalar in string.unicodeScalars {
        utf16Length += scalar.value > 0xFFFF ? 2 : 1
        displayColumnCount += domTreeDisplayColumnCount(for: scalar)
    }
    return DOMTreeTextMetrics(
        utf16Length: utf16Length,
        displayColumnCount: displayColumnCount
    )
}

private func domTreeASCIIColumnCount(for byte: UInt8) -> Int {
    switch byte {
    case 0x09:
        return 4
    case 0x0A, 0x0D:
        return 0
    default:
        return 1
    }
}

private func domTreeDisplayColumnCount(for scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case 0x09:
        return 4
    case 0x0A, 0x0D:
        return 0
    case 0xFE00...0xFE0F, 0xE0100...0xE01EF, 0x200B, 0x200D:
        return 0
    default:
        break
    }

    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
        return 0
    case .control, .format:
        return 0
    default:
        break
    }

    if scalar.isASCII {
        return 1
    }

    // Conservative non-ASCII sizing prevents full-width and fallback glyphs from being clipped
    // without returning to per-line glyph measurement on the main thread.
    return 2
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

    static func markup(
        for node: DOMNodeModel,
        hasDisclosure: Bool,
        isOpen: Bool,
        isClosingTag: Bool
    ) -> DOMTreeMarkup {
        if isClosingTag {
            return closingElementMarkup(for: node)
        }

        switch inferredNodeType(for: node) {
        case .element:
            return elementMarkup(for: node, hasDisclosure: hasDisclosure, isOpen: isOpen)
        case .text:
            return textMarkup(for: node)
        case .comment:
            return commentMarkup(for: node)
        case .documentType:
            return documentTypeMarkup(for: node)
        case .documentFragment:
            return documentFragmentMarkup(for: node)
        case .cdataSection:
            return cdataMarkup(for: node)
        case .processingInstruction:
            return processingInstructionMarkup(for: node)
        case .document:
            return fallbackMarkup("#document")
        default:
            return fallbackMarkup(fallbackPreview(for: node))
        }
    }

    static func rendersClosingTagRow(for node: DOMNodeModel) -> Bool {
        guard inferredNodeType(for: node) == .element else {
            return false
        }
        guard node.pseudoType == nil else {
            return false
        }
        return !voidElementNames.contains(elementName(for: node))
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
        if let pseudoType = node.pseudoType {
            return fallbackMarkup("::\(pseudoType)")
        }

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
                markup.append("…", kind: .fallback)
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

    private static func closingElementMarkup(for node: DOMNodeModel) -> DOMTreeMarkup {
        let name = elementName(for: node)
        var markup = DOMTreeMarkup()
        markup.append("</", kind: .punctuation)
        markup.append(name, kind: .tagName)
        markup.append(">", kind: .punctuation)
        return markup
    }

    private static func documentFragmentMarkup(for node: DOMNodeModel) -> DOMTreeMarkup {
        if let shadowRootType = node.shadowRootType {
            return fallbackMarkup("Shadow Content (\(shadowRootTypeDisplayName(shadowRootType)))")
        }
        if let parent = node.parent,
           parent.templateContent === node {
            return fallbackMarkup("Template Content")
        }
        return fallbackMarkup("Document Fragment")
    }

    private static func shadowRootTypeDisplayName(_ rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "user-agent", "useragent":
            "User Agent"
        case "open":
            "Open"
        case "closed":
            "Closed"
        default:
            rawValue
        }
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

private extension DOMTreeInvalidation {
    var requiresTextFragmentReset: Bool {
        if case .documentReset = self {
            return true
        }
        return false
    }

    func merged(with other: DOMTreeInvalidation) -> DOMTreeInvalidation {
        switch (self, other) {
        case (.documentReset, _), (_, .documentReset):
            return .documentReset
        case let (.structural(lhs), .structural(rhs)),
             let (.structural(lhs), .content(rhs)),
             let (.content(lhs), .structural(rhs)):
            return .structural(affectedKeys: lhs.union(rhs))
        case let (.content(lhs), .content(rhs)):
            return .content(affectedKeys: lhs.union(rhs))
        }
    }
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
    var hoverRowColor: CGColor?
    var selectedRowRects: [CGRect] = []
    var multiSelectedRowRects: [CGRect] = []
    var selectedRowColor: CGColor?
    var findHighlightRects: [CGRect] = []
    var findHighlightColor: CGColor?
    var currentFindHighlightRects: [CGRect] = []
    var currentFindHighlightColor: CGColor?

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

        if let hoverRowColor, !hoverRowRects.isEmpty {
            context.saveGState()
            context.setFillColor(hoverRowColor)
            for rowRect in hoverRowRects where rowRect.intersects(rect) {
                context.fill(rowRect)
            }
            context.restoreGState()
        }

        if let selectedRowColor, !selectedRowRects.isEmpty || !multiSelectedRowRects.isEmpty {
            context.saveGState()
            context.setFillColor(selectedRowColor)
            for rowRect in multiSelectedRowRects where rowRect.intersects(rect) {
                context.fill(rowRect)
            }
            for rowRect in selectedRowRects where rowRect.intersects(rect) {
                context.fill(rowRect)
            }
            context.restoreGState()
        }

        if let findHighlightColor, !findHighlightRects.isEmpty {
            context.saveGState()
            context.setFillColor(findHighlightColor)
            for findRect in findHighlightRects where findRect.intersects(rect) {
                context.fill(findRect)
            }
            context.restoreGState()
        }

        if let currentFindHighlightColor, !currentFindHighlightRects.isEmpty {
            context.saveGState()
            context.setFillColor(currentFindHighlightColor)
            for findRect in currentFindHighlightRects where findRect.intersects(rect) {
                context.fill(findRect)
            }
            context.restoreGState()
        }

        layoutFragment.draw(at: layoutFragmentDrawPoint, in: context)
    }
}

private struct DisclosureSymbolImageCacheKey: Hashable {
    let userInterfaceStyle: UIUserInterfaceStyle
    let isOpen: Bool
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
