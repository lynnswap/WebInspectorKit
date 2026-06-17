#if canImport(UIKit)
import WebInspectorCore
import Observation
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
final class DOMTreeTextView: UIScrollView, UITextInput, UITextInteractionDelegate {
    typealias RequestChildrenAction = @MainActor (DOMNode.ID) async -> Bool
    typealias HighlightNodeAction = @MainActor (DOMNode.ID, DOMPageHighlightOwner) async -> Void
    typealias RestoreHighlightAction = @MainActor () async -> Void
    typealias CopyNodeTextAction = DOMTreeMenuCopyNodeTextAction
    typealias DeleteNodesAction = DOMTreeMenuDeleteNodesAction

    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let lineSpacing: CGFloat = 2
    private static let textInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 16)
    private static let characterWidth: CGFloat = {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }()
    private static let disclosureSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
    private static let paragraphLineHeight: CGFloat = {
        ceil(font.lineHeight + lineSpacing)
    }()
    static let textBaselineOffset: CGFloat = {
        (paragraphLineHeight - font.lineHeight) / 2
    }()
    static let paragraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.minimumLineHeight = paragraphLineHeight
        paragraphStyle.maximumLineHeight = paragraphLineHeight
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        return paragraphStyle
    }()
    private let dom: DOMSession
    private let menuModel: DOMTreeMenuModel
    private var documentObservation: PortableObservationTracking.Token?
    private var selectionObservation: PortableObservationTracking.Token?
    private let textContentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer()
    private let textContentView = DOMTreeTextContentView()
    private lazy var viewportLayoutDelegate = DOMTreeTextViewportLayoutDelegate(textView: self)
    private lazy var viewportLayoutCoordinator = DOMTreeTextView.ViewportLayoutCoordinator(textContentView: textContentView)
    private lazy var findCoordinator = DOMTreeTextView.FindCoordinator(textView: self)
    private lazy var textSelectionInteraction: UITextInteraction = {
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.delegate = self
        interaction.textInput = self
        return interaction
    }()
    private lazy var textInputTokenizer = UITextInputStringTokenizer(textInput: self)
    private lazy var domMenuHostingMenu = UIHostingMenu(
        rootView: DOMTreeMenuView(model: menuModel)
    )

    private var renderedRows = DOMTreeTextView.RenderedRows()
    private var rows: [DOMTreeTextView.Line] {
        get {
            renderedRows.rows
        }
        set {
            renderedRows.replaceRows(newValue)
        }
    }
    private var renderedText = ""
    private let expansionState: DOMTreeTextView.ExpansionState
    private let renderedRowsBuildCoordinator: DOMTreeTextView.RenderedRowsBuildCoordinator
    private var hoveredNodeID: DOMNode.ID?
    private var pageHighlightTask: Task<Void, Never>?
    private var requestedChildNodeIDs: Set<DOMNode.ID> = []
    private let findDecorationState = DOMTreeTextView.FindDecorationState()
    private var hoverRowRects: [CGRect] = []
    private var selectedRowRects: [CGRect] = []
    private var multiSelectedRowRects: [CGRect] = []
    private var measuredTextWidth: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var lastRenderedDocumentRootID: DOMNode.ID?
    private var lastRoutedTreeRevision: UInt64?
    private var lastObservedTreeContent: DOMTreeTextView.ObservedContent?
    private var lastRoutedSelectedNodeID: DOMNode.ID?
    private let selectionRevealState = DOMTreeTextView.SelectionRevealState()
    private var resolvedTextAttributesCache: DOMTreeTextView.ResolvedTextAttributes?
    private var disclosureSymbolImageCache: [DisclosureSymbolImageCacheKey: UIImage] = [:]
    private var maxLineDisplayColumnCount = 0
    private var multiSelection = DOMTreeTextView.SelectionController()
    private var menuAnchorButton: UIButton?
    private var selectedTextNSRange = NSRange(location: 0, length: 0)
    private var markedTextNSRange: NSRange?
    private var markedTextStyleStorage: [NSAttributedString.Key: Any]?
    private let requestChildrenAction: RequestChildrenAction?
    private let highlightNodeAction: HighlightNodeAction?
    private let restoreHighlightAction: RestoreHighlightAction?
    weak var inputDelegate: UITextInputDelegate?
#if DEBUG
    private let performanceCounters = DOMTreeTextView.PerformanceCounters()
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

    private enum PageHighlightReason {
        case selection
        case hover

        var owner: DOMPageHighlightOwner {
            switch self {
            case .selection:
                .selection
            case .hover:
                .transient
            }
        }
    }

    init(
        dom: DOMSession,
        requestChildrenAction: RequestChildrenAction? = nil,
        highlightNodeAction: HighlightNodeAction? = nil,
        restoreHighlightAction: RestoreHighlightAction? = nil,
        copyNodeTextAction: CopyNodeTextAction? = nil,
        deleteNodesAction: DeleteNodesAction? = nil
    ) {
        self.dom = dom
        self.requestChildrenAction = requestChildrenAction
        self.highlightNodeAction = highlightNodeAction
        self.restoreHighlightAction = restoreHighlightAction
        let expansionState = DOMTreeTextView.ExpansionState()
        self.expansionState = expansionState
        self.renderedRowsBuildCoordinator = DOMTreeTextView.RenderedRowsBuildCoordinator(
            builder: DOMTreeTextView.RenderedRowsBuilder(dom: dom, expansionState: expansionState)
        )
        self.menuModel = DOMTreeMenuModel(
            dom: dom,
            copyNodeTextAction: copyNodeTextAction,
            deleteNodesAction: deleteNodesAction
        )
        super.init(frame: .zero)
        configureTextSystem()
        configureInteractions()
        startObservingDocument()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        pageHighlightTask?.cancel()
        renderedRowsBuildCoordinator.cancel()
        documentObservation?.cancel()
        selectionObservation?.cancel()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: String(localized: "dom.tree.extend_selection_up", bundle: .module),
                action: #selector(extendMultiSelectionUp),
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: .shift,
                discoverabilityTitle: String(localized: "dom.tree.extend_selection_up", bundle: .module)
            ),
            UIKeyCommand(
                title: String(localized: "dom.tree.extend_selection_down", bundle: .module),
                action: #selector(extendMultiSelectionDown),
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: .shift,
                discoverabilityTitle: String(localized: "dom.tree.extend_selection_down", bundle: .module)
            ),
            UIKeyCommand(
                title: String(localized: "dom.tree.select_all", bundle: .module),
                action: #selector(selectAllRenderedRows),
                input: "a",
                modifierFlags: .command,
                discoverabilityTitle: String(localized: "dom.tree.select_all", bundle: .module)
            ),
            UIKeyCommand(
                title: String(localized: "dom.tree.find", bundle: .module),
                action: #selector(showFindNavigator),
                input: "f",
                modifierFlags: .command,
                discoverabilityTitle: String(localized: "dom.tree.find", bundle: .module)
            )
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard lastBoundsSize != bounds.size || textContentView.frame.isEmpty else {
            layoutManager.textViewportLayoutController.layoutViewport()
            revealPendingSelectedNodeIfPossible()
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
        viewportLayoutCoordinator.prepareForLayout()
    }

    func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        viewportLayoutCoordinator.configureRenderingSurface(
            for: textLayoutFragment,
            visibleTextRect: visibleTextRect(),
            configureHighlights: { [unowned self] fragmentView, surfaceFrame in
                configureHighlights(for: fragmentView, surfaceFrame: surfaceFrame)
            },
            configureRowBackgrounds: { [unowned self] fragmentView, surfaceFrame in
                configureRowBackgrounds(for: fragmentView, surfaceFrame: surfaceFrame)
            }
        )
    }

    func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        viewportLayoutCoordinator.finishLayout()
        updateTextLayoutGeometry()
    }

    @objc private func showFindNavigator() {
        becomeFirstResponder()
        findCoordinator.findInteraction.presentFindNavigator(showingReplace: false)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }
        let location = recognizer.location(in: textContentView)
        guard let row = row(at: location) else {
            return
        }
        let disclosureHit = isDisclosureHit(at: location, in: row)

        dismissDOMMenuAnchor()
        clearTextSelection()
        if disclosureHit {
            toggle(row: row)
        } else if recognizer.modifierFlags.contains(.shift) {
            extendMultiSelection(to: row)
        } else if recognizer.modifierFlags.contains(.command) || recognizer.modifierFlags.contains(.control) {
            toggleMultiSelection(row: row)
        } else {
            clearMultiSelection(keepingLast: row.nodeID)
            select(row.nodeID)
        }
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let row = row(at: recognizer.location(in: textContentView))
        else {
            return
        }

        let nodes: [DOMNode]
        if multiSelection.selectedCount > 1, multiSelection.contains(row.nodeID) {
            nodes = multiSelectedNodesInDisplayOrder()
        } else {
            clearMultiSelection(keepingLast: row.nodeID)
            nodes = dom.node(for: row.nodeID).map { [$0] } ?? []
            select(row.nodeID)
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
        multiSelection.selectAll(rows: rows)
        updateContentDecorations()
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            guard let row = row(at: recognizer.location(in: textContentView)) else {
                clearHoveredRowAndRestoreSelectionHighlight()
                return
            }
            hover(row: row)
        case .ended, .cancelled, .failed:
            clearHoveredRowAndRestoreSelectionHighlight()
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
        applyFindDecorationInvalidation(
            findDecorationState.decorate(clampedRange, style: style)
        )
    }

    func clearFindDecorations() {
        applyFindDecorationInvalidation(findDecorationState.clear())
    }

    func beginFindDecorationBatch() {
        findDecorationState.beginBatch()
    }

    func endFindDecorationBatch() {
        applyFindDecorationInvalidation(findDecorationState.endBatch())
    }

    private func applyFindDecorationInvalidation(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else {
            return
        }
        setNeedsDisplayForTextRanges(ranges)
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
           isDisclosureHit(at: contentPoint, in: row) {
            return false
        }
        dismissDOMMenuAnchor()
        clearMultiSelection(keepingLast: multiSelection.lastNodeID)
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
        layoutManager.renderingAttributesValidator = { [weak self] textLayoutManager, textLayoutFragment in
            MainActor.assumeIsolated {
                self?.validateTokenRenderingAttributes(
                    in: textLayoutFragment,
                    using: textLayoutManager
                )
            }
        }
        layoutManager.textViewportLayoutController.delegate = viewportLayoutDelegate
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
        documentObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else { return }
            let treeRevision = dom.treeRevision
            let shouldRouteDOMInvalidation = event.kind == .initial || lastRoutedTreeRevision != treeRevision
            lastRoutedTreeRevision = treeRevision
            guard shouldRouteDOMInvalidation else {
                return
            }
            routeDOMInvalidation(from: dom, isInitial: event.kind == .initial)
        }
        selectionObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            _ = dom.selectionRevision
            routeSelectionInvalidation(from: dom)
        }
    }

    private func routeDOMInvalidation(from dom: DOMSession, isInitial: Bool) {
#if DEBUG
        performanceCounters.buildRenderedRowsCallCount += 1
#endif
        resetLocalDocumentStateIfNeeded()
        prepareSelectionForRendering()
        startRenderedRowsBuild(
            resetFragments: true,
            previousRows: rows,
            previousText: renderedText,
            shouldApply: { [weak self] result in
                guard let self else {
                    return false
                }
                let nextTreeContent = result.observedContent
                let treeChanged = isInitial || self.lastObservedTreeContent != nextTreeContent
                self.lastObservedTreeContent = nextTreeContent
                return treeChanged
            }
        )
    }

    private func routeSelectionInvalidation(from dom: DOMSession) {
        let nextSelectedNodeID = dom.selectedNodeID
        guard lastRoutedSelectedNodeID != nextSelectedNodeID else {
            return
        }
        handleSelectedNodeChange()
    }

    private func handleSelectedNodeChange() {
        let previousOpenState = expansionState.snapshot
        prepareSelectionForRendering(clearsMultiSelectionForDocumentSelection: true)
        if previousOpenState != expansionState.snapshot || selectedNodeNeedsRowReload() {
            reloadTree(resetFragments: false)
            return
        }
        updateContentDecorations()
        revealPendingSelectedNodeIfPossible()
    }

    private func reloadTree(resetFragments: Bool, countsCall: Bool = true) {
#if DEBUG
        if countsCall {
            performanceCounters.reloadTreeCallCount += 1
        }
#endif
        startRenderedRowsReload(resetFragments: resetFragments, countsCall: false)
    }

    private func startRenderedRowsReload(
        resetFragments: Bool,
        countsCall: Bool = true
    ) {
#if DEBUG
        if countsCall {
            performanceCounters.reloadTreeCallCount += 1
        }
#endif
        resetLocalDocumentStateIfNeeded()
        let previousRows = rows
        let previousText = renderedText
        if resetFragments {
            renderedRowsBuildCoordinator.removeCachedMarkup(keepingCapacity: true)
        }
        prepareSelectionForRendering()
#if DEBUG
        performanceCounters.buildRenderedRowsCallCount += 1
#endif
        startRenderedRowsBuild(
            resetFragments: resetFragments,
            previousRows: previousRows,
            previousText: previousText
        )
    }

    private func startRenderedRowsBuild(
        resetFragments: Bool,
        previousRows: [DOMTreeTextView.Line],
        previousText: String,
        shouldApply: (@MainActor (DOMTreeTextView.RenderedRowsBuildResult) -> Bool)? = nil
    ) {
        renderedRowsBuildCoordinator.startBuild(
            previousRowCapacity: rows.count,
            previousTextCapacity: renderedText.count,
            isCurrentBuild: { [weak self] request in
                guard let self else {
                    return false
                }
                return dom.treeRevision == request.treeRevision
                    && expansionState.snapshot == request.expansionState
            },
            shouldApply: shouldApply,
            apply: { [weak self] buildResult in
                guard let self else {
                    return
                }
                applyRenderedRowsBuildResult(
                    buildResult,
                    resetFragments: resetFragments,
                    previousRows: previousRows,
                    previousText: previousText
                )
            },
            didFinish: { [weak self] in
                self?.revealPendingSelectedNodeIfPossible()
            }
        )
    }

    private func applyRenderedRowsBuildResult(
        _ buildResult: DOMTreeTextView.RenderedRowsBuildResult,
        resetFragments: Bool,
        previousRows: [DOMTreeTextView.Line],
        previousText: String
    ) {
        rows = buildResult.rows
        lastObservedTreeContent = buildResult.observedContent
        renderedRowsBuildCoordinator.pruneCachedMarkup(keeping: renderedRows.visibleNodeIDs)
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
    }

    private func resetLocalDocumentStateIfNeeded() {
        let rootID = dom.currentPageRootNode?.id
        defer {
            lastRenderedDocumentRootID = rootID
        }
        guard rootID == nil
                || (lastRenderedDocumentRootID != nil && lastRenderedDocumentRootID != rootID) else {
            return
        }

        expansionState.removeAll()
        hoveredNodeID = nil
        requestedChildNodeIDs.removeAll(keepingCapacity: true)
        hoverRowRects.removeAll(keepingCapacity: true)
        selectedRowRects.removeAll(keepingCapacity: true)
        multiSelectedRowRects.removeAll(keepingCapacity: true)
        selectionRevealState.reset()
        multiSelection.reset()
        dismissDOMMenuAnchor()
        clearTextSelection()
    }

    private func prepareSelectionForRendering(clearsMultiSelectionForDocumentSelection: Bool = false) {
        let nextSelectedNodeID = dom.selectedNodeID
        let selectedNodeIDChanged = lastRoutedSelectedNodeID != nextSelectedNodeID
        lastRoutedSelectedNodeID = nextSelectedNodeID
        let selectedNode = nextSelectedNodeID.flatMap { dom.node(for: $0) }
        let observation = selectionRevealState.observe(selectedNodeID: selectedNode?.id)
        reconcileMultiSelectionForRenderedSelection(
            selectedNodeID: observation.selectedNodeID,
            selectedNodeIDChanged: selectedNodeIDChanged || observation.selectedNodeIDChanged,
            clearsMultiSelectionForDocumentSelection: clearsMultiSelectionForDocumentSelection
        )

        guard let selectedNode else {
            selectionRevealState.clearPendingSelection()
            return
        }
        openAncestors(of: selectedNode)
    }

    private func reconcileMultiSelectionForRenderedSelection(
        selectedNodeID: DOMNode.ID?,
        selectedNodeIDChanged: Bool,
        clearsMultiSelectionForDocumentSelection: Bool
    ) {
        if multiSelection.reconcileRenderedSelection(
            selectedNodeID: selectedNodeID,
            selectedNodeIDChanged: selectedNodeIDChanged,
            clearsMultiSelectionForDocumentSelection: clearsMultiSelectionForDocumentSelection
        ) {
            updateContentDecorations()
        }
    }

    private func openAncestors(of node: DOMNode) {
        guard let rootTargetID = dom.currentPageTargetID else {
            return
        }
        let projection = dom.treeProjection(rootTargetID: rootTargetID)
        for ancestorID in projection.ancestorNodeIDs(of: node.id) {
            guard let ancestor = dom.node(for: ancestorID) else {
                continue
            }
            if ancestor.nodeType != .document || projection.parent(of: ancestor.id) != nil {
                expansionState.setIsOpen(true, for: ancestor.id)
            }
        }
    }

    private func updateMeasuredTextWidth() {
        measuredTextWidth = CGFloat(maxLineDisplayColumnCount) * Self.characterWidth
    }

    private func pruneChildRequestState() {
        requestedChildNodeIDs = requestedChildNodeIDs.filter { nodeID in
            guard let node = dom.node(for: nodeID) else {
                return false
            }
            return dom.hasUnloadedRegularChildren(node)
        }
    }

    private func requestChildrenForOpenRowsIfNeeded() {
        guard dom.currentPageRootNode != nil else {
            return
        }
        for row in rows where row.hasDisclosure && row.isOpen {
            guard let node = dom.node(for: row.nodeID) else {
                continue
            }
            requestChildrenIfNeeded(for: node)
        }
    }

    private func requestChildrenIfNeeded(for node: DOMNode) {
        guard dom.hasUnloadedRegularChildren(node),
              requestedChildNodeIDs.insert(node.id).inserted
        else {
            return
        }
        Task { @MainActor [weak self, requestChildrenAction, nodeID = node.id] in
            guard let self else {
                return
            }
            defer {
                self.requestedChildNodeIDs.remove(nodeID)
            }
            _ = await requestChildrenAction?(nodeID) ?? false
        }
    }

    private func toggle(row: DOMTreeTextView.Line) {
        expansionState.setIsOpen(!row.isOpen, for: row.nodeID)
        reloadTree(resetFragments: false)
    }

    private func select(_ nodeID: DOMNode.ID) {
        multiSelection.notePrimarySelection(nodeID)
        dom.selectNode(nodeID)
        highlightPageNode(nodeID, reason: .selection)
    }

    private func toggleMultiSelection(row: DOMTreeTextView.Line) {
        multiSelection.toggle(
            row: row,
            renderedRows: renderedRows,
            selectedNodeID: dom.selectedNodeID
        )
        updateContentDecorations()
    }

    private func extendMultiSelection(to row: DOMTreeTextView.Line) {
        if multiSelection.extend(
            to: row,
            renderedRows: renderedRows,
            selectedNodeID: dom.selectedNodeID
        ) {
            updateContentDecorations()
        }
    }

    private func extendMultiSelectionByKeyboard(delta: Int) {
        guard !rows.isEmpty else {
            return
        }

        let focusedNodeID = multiSelection.focusedNodeID(
            selectedNodeID: dom.selectedNodeID,
            fallbackNodeID: rows.first?.nodeID
        )
        guard let focusedNodeID,
              let focusedIndex = renderedRows.rowIndex(for: focusedNodeID)
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

    private func clearMultiSelection(keepingLast nodeID: DOMNode.ID?) {
        multiSelection.clear(keepingLast: nodeID)
        updateContentDecorations()
    }

    private func reconcileMultiSelectionAfterReload() {
        multiSelection.reconcileAfterReload(visibleNodeIDs: renderedRows.visibleNodeIDs)
    }

    private func multiSelectedNodesInDisplayOrder() -> [DOMNode] {
        multiSelection.selectedNodeIDsInDisplayOrder(rows: rows).compactMap { dom.node(for: $0) }
    }

    private func scrollRowToVisible(_ row: DOMTreeTextView.Line) {
        let rowRect = modelContentRowRect(for: row)
        let headRect = modelRowHeadRect(for: row)
        let targetRect = CGRect(
            x: Self.textInsets.left + headRect.minX,
            y: Self.textInsets.top + rowRect.minY,
            width: max(1, headRect.width),
            height: rowRect.height
        )
        scrollRectToVisible(targetRect.insetBy(dx: 0, dy: -rowRect.height), animated: true)
    }

    private func modelContentRowRect(for row: DOMTreeTextView.Line) -> CGRect {
        // DOM tree rows are fixed-height; reveal must not depend on TextKit fragment rects while layout catches up.
        CGRect(
            x: 0,
            y: CGFloat(row.rowIndex) * rowHeight,
            width: max(textContentView.bounds.width, contentSize.width - Self.textInsets.left - Self.textInsets.right),
            height: rowHeight
        )
    }

    private func modelRowHeadRect(for row: DOMTreeTextView.Line) -> CGRect {
        let column: Int
        let widthInColumns: Int
        if row.hasDisclosure {
            column = row.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth
            widthInColumns = DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
        } else {
            column = row.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth
                + DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
            widthInColumns = 1
        }
        return CGRect(
            x: CGFloat(column) * Self.characterWidth,
            y: CGFloat(row.rowIndex) * rowHeight,
            width: CGFloat(widthInColumns) * Self.characterWidth,
            height: rowHeight
        )
    }

    private func row(at location: CGPoint) -> DOMTreeTextView.Line? {
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

    private func hover(row: DOMTreeTextView.Line) {
        if hoveredNodeID != row.nodeID {
            hoveredNodeID = row.nodeID
            updateContentDecorations()
        }
        highlightPageNode(row.nodeID, reason: .hover)
    }

    private func highlightPageNode(_ nodeID: DOMNode.ID, reason: PageHighlightReason) {
        pageHighlightTask?.cancel()
        pageHighlightTask = Task { @MainActor [weak self, highlightNodeAction] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self else {
                return
            }
            guard !self.dom.isSelectingElement else {
                return
            }
            switch reason {
            case .selection:
                guard self.dom.selectedNodeID == nodeID else {
                    return
                }
            case .hover:
                guard self.hoveredNodeID == nodeID else {
                    return
                }
            }
            guard !Task.isCancelled else {
                return
            }
            await highlightNodeAction?(nodeID, reason.owner)
        }
    }

    private func clearHoveredRowAndRestoreSelectionHighlight() {
        pageHighlightTask?.cancel()
        clearHoveredRow()
        pageHighlightTask = Task { @MainActor [weak self, restoreHighlightAction] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.hoveredNodeID == nil,
                  !self.dom.isSelectingElement else {
                return
            }
            await restoreHighlightAction?()
        }
    }

    private func presentDOMMenu(for nodes: [DOMNode], at location: CGPoint) {
        let menu = makeDOMMenu(for: nodes)

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

    private func makeDOMMenu(for nodes: [DOMNode], selectedText: String? = nil) -> UIMenu {
        makeMenu(
            for: uniqueNodeIDsInDisplayOrder(for: nodes),
            selectedText: selectedText
        )
    }

    private func makeTextSelectionEditMenu(for range: NSRange) -> UIMenu {
        let selectedRows = rowsIntersectingTextRange(range)
        let nodes = uniqueNodesInDisplayOrder(for: selectedRows)
        guard !nodes.isEmpty else {
            return UIMenu(children: [])
        }
        let selectedText = selectedRows.count == 1 ? text(in: DOMTreeTextRange(range: range)) : nil
        return makeDOMMenu(for: nodes, selectedText: selectedText)
    }

    private func rowsIntersectingTextRange(_ range: NSRange) -> [DOMTreeTextView.Line] {
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

    private func uniqueNodesInDisplayOrder(for rows: [DOMTreeTextView.Line]) -> [DOMNode] {
        var seenNodeIDs: Set<DOMNode.ID> = []
        return rows.compactMap { row in
            guard seenNodeIDs.insert(row.nodeID).inserted else {
                return nil
            }
            return dom.node(for: row.nodeID)
        }
    }

    private func makeMenu(for nodeIDs: [DOMNode.ID], selectedText: String?) -> UIMenu {
        menuModel.configure(
            nodeIDs: nodeIDs,
            selectedText: selectedText,
            undoManager: undoManager,
            localMarkupTextByNodeID: localMarkupTextByNodeID(for: nodeIDs),
            clearLocalSelection: { [weak self] in
                self?.clearTextSelection()
                self?.clearMultiSelection(keepingLast: nil)
            }
        )
        return (try? domMenuHostingMenu.menu()) ?? UIMenu(children: [])
    }

    private func localMarkupText(for nodeID: DOMNode.ID) -> String? {
        rows.first { !$0.isClosingTag && $0.nodeID == nodeID }?.text
    }

    private func uniqueNodeIDsInDisplayOrder(for nodes: [DOMNode]) -> [DOMNode.ID] {
        var seenNodeIDs: Set<DOMNode.ID> = []
        return nodes.compactMap { node in
            seenNodeIDs.insert(node.id).inserted ? node.id : nil
        }
    }

    private func localMarkupTextByNodeID(for nodeIDs: [DOMNode.ID]) -> [DOMNode.ID: String] {
        Dictionary(
            uniqueKeysWithValues: nodeIDs.compactMap { nodeID in
                localMarkupText(for: nodeID).map { (nodeID, $0) }
            }
        )
    }

    private func baseTextAttributes() -> [NSAttributedString.Key: Any] {
        resolvedTextAttributes().base
    }

    private func resolvedTextAttributes() -> DOMTreeTextView.ResolvedTextAttributes {
        let style = traitCollection.userInterfaceStyle
        if let cached = resolvedTextAttributesCache,
           cached.userInterfaceStyle == style {
            return cached
        }
        let resolved = DOMTreeTextView.ResolvedTextAttributes(traitCollection: traitCollection)
        resolvedTextAttributesCache = resolved
        return resolved
    }

    private func validateTokenRenderingAttributes(
        in textLayoutFragment: NSTextLayoutFragment,
        using textLayoutManager: NSTextLayoutManager
    ) {
        let fragmentRange = textRange(for: textLayoutFragment)
        guard fragmentRange.length > 0 else {
            return
        }

        let resolvedAttributes = resolvedTextAttributes()
        let fallbackColor = resolvedAttributes.tokenColors[.fallback]
            ?? DOMTreeTextView.HighlightTheme.webInspector.textSecondary.resolvedColor(with: traitCollection)
        let disclosureColor = DOMTreeTextView.HighlightTheme.webInspector.disclosure.resolvedColor(with: traitCollection)
        for row in rowsIntersectingTextRange(fragmentRange) {
            addRenderingAttribute(
                .foregroundColor,
                value: fallbackColor,
                range: NSIntersectionRange(row.textRange, fragmentRange),
                using: textLayoutManager
            )
            if row.hasDisclosure {
                addRenderingAttribute(
                    .foregroundColor,
                    value: disclosureColor,
                    range: NSIntersectionRange(disclosureAttachmentRange(for: row), fragmentRange),
                    using: textLayoutManager
                )
            }
            for token in row.tokens {
                let tokenRange = NSRange(
                    location: row.textRange.location + token.range.location,
                    length: token.range.length
                )
                let color = resolvedAttributes.tokenColors[token.kind] ?? fallbackColor
                addRenderingAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSIntersectionRange(tokenRange, fragmentRange),
                    using: textLayoutManager
                )
            }
        }
    }

    private func addRenderingAttribute(
        _ attributeName: NSAttributedString.Key,
        value: Any,
        range: NSRange,
        using textLayoutManager: NSTextLayoutManager
    ) {
        guard range.length > 0,
              let textRange = textRange(for: range)
        else {
            return
        }
        textLayoutManager.addRenderingAttribute(attributeName, value: value, for: textRange)
    }

    private func invalidateTokenRenderingAttributes(for ranges: [NSRange]) {
        guard !ranges.isEmpty else {
            setNeedsDisplayForVisibleTextFragments()
            return
        }

        var invalidatedRanges: [NSRange] = []
        invalidatedRanges.reserveCapacity(ranges.count)
        for range in ranges {
            let clampedRange = clampedTextRange(range)
            guard clampedRange.length > 0,
                  let textRange = textRange(for: clampedRange)
            else {
                continue
            }
            layoutManager.invalidateRenderingAttributes(for: textRange)
            invalidatedRanges.append(clampedRange)
        }

        guard !invalidatedRanges.isEmpty else {
            setNeedsDisplayForVisibleTextFragments()
            return
        }

        var didInvalidateFragment = false
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            guard !Self.ranges(invalidatedRanges, intersecting: fragmentRange).isEmpty else {
                continue
            }
            validateTokenRenderingAttributes(in: fragmentView.layoutFragment, using: layoutManager)
            fragmentView.setNeedsDisplay()
            didInvalidateFragment = true
        }
        if !didInvalidateFragment {
            setNeedsDisplayForVisibleTextFragments()
        }
    }

    private func reapplyTextAttributes() {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else {
            return
        }
        textStorage.addAttributes(baseTextAttributes(), range: fullRange)
        applyDisclosureAttachments(to: textStorage, rows: rows)
        invalidateTokenRenderingAttributes(for: [fullRange])
    }

    private func rebuildTextStorage() {
        let attributedText = NSMutableAttributedString(
            string: renderedText.isEmpty ? "\n" : renderedText,
            attributes: baseTextAttributes()
        )
        applyDisclosureAttachments(to: attributedText, rows: rows)
#if DEBUG
        performanceCounters.rebuildTextStorageCallCount += 1
#endif
        textContentStorage.performEditingTransaction {
            textStorage.setAttributedString(attributedText)
        }
        invalidateTextLayout()
        invalidateTokenRenderingAttributes(for: rows.map(\.textRange))
    }

    private func updateTextStorageIncrementally(
        previousRows: [DOMTreeTextView.Line],
        previousText: String,
        nextRows: [DOMTreeTextView.Line],
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
        performanceCounters.incrementalTextStorageEditCallCount += 1
#endif

        let changedRows = Array(nextRows[diff.nextStart..<diff.nextEnd])
        applyTextAttributes(to: changedRows)
        invalidateTokenRenderingAttributes(for: changedRows.map(\.textRange))
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            setNeedsDisplayForTextRanges(changedRows.map(\.textRange))
        }
    }

    private func rowDiff(
        previousRows: [DOMTreeTextView.Line],
        nextRows: [DOMTreeTextView.Line]
    ) -> DOMTreeTextView.RowDiff? {
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
        return DOMTreeTextView.RowDiff(
            previousStart: prefix,
            previousEnd: previousSuffix,
            nextStart: prefix,
            nextEnd: nextSuffix
        )
    }

    private func textEdit(
        previousRows: [DOMTreeTextView.Line],
        previousText: String,
        nextRows: [DOMTreeTextView.Line],
        diff: DOMTreeTextView.RowDiff
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

    private func applyTextAttributes(to rows: [DOMTreeTextView.Line]) {
        guard !rows.isEmpty else {
            return
        }
        for row in rows {
            guard row.textRange.location + row.textRange.length <= textStorage.length else {
                continue
            }
            textStorage.addAttributes(baseTextAttributes(), range: row.textRange)
        }
        applyDisclosureAttachments(to: textStorage, rows: rows)
    }

    private func applyDisclosureAttachments(to attributedText: NSMutableAttributedString, rows: [DOMTreeTextView.Line]) {
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
        let disclosureColor = DOMTreeTextView.HighlightTheme.webInspector.disclosure.resolvedColor(with: traitCollection)
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
        performanceCounters.resetTextFragmentViewsCallCount += 1
#endif
        viewportLayoutCoordinator.resetFragmentViews()
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
        if findDecorationState.isEmpty {
            foundRects = []
            highlightedRects = []
        } else {
            let fragmentRange = textRange(for: fragmentView.layoutFragment)
            foundRects = textRects(
                in: surfaceFrame,
                ranges: Self.ranges(findDecorationState.foundRanges, intersecting: fragmentRange)
            )
            highlightedRects = textRects(
                in: surfaceFrame,
                ranges: Self.ranges(findDecorationState.highlightedRanges, intersecting: fragmentRange)
            )
        }
        let foundColor = foundRects.isEmpty
            ? nil
            : DOMTreeTextView.HighlightTheme.webInspector.findBackground.resolvedColor(with: traitCollection).cgColor
        let highlightedColor = highlightedRects.isEmpty
            ? nil
            : DOMTreeTextView.HighlightTheme.webInspector.currentFindBackground.resolvedColor(with: traitCollection).cgColor
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
        guard !multiSelection.hasExplicitSelection else {
            return []
        }
        guard let selectedNodeID = dom.selectedNodeID else {
            return []
        }
        return rowRects(for: selectedNodeID)
    }

    private func selectedNodeNeedsRowReload() -> Bool {
        guard let selectedNodeID = dom.selectedNodeID else {
            return false
        }
        return !renderedRows.contains(nodeID: selectedNodeID)
    }

    private func multiSelectionContentRowRects() -> [CGRect] {
        rows.flatMap { row in
            !row.isClosingTag && multiSelection.contains(row.nodeID) ? contentRowRects(for: row) : []
        }
    }

    private func hoverContentRowRects() -> [CGRect] {
        guard let hoveredNodeID else {
            return []
        }
        return rowRects(for: hoveredNodeID)
    }

    private func rowRects(for nodeID: DOMNode.ID) -> [CGRect] {
        guard let row = renderedRows.row(for: nodeID) else {
            return []
        }
        return contentRowRects(for: row)
    }

    private func contentRowRects(for row: DOMTreeTextView.Line) -> [CGRect] {
        textSegmentRects(for: row.textRange, type: .highlight).map { textRect in
            CGRect(
                x: 0,
                y: textRect.minY,
                width: max(textContentView.bounds.width, contentSize.width - Self.textInsets.left - Self.textInsets.right),
                height: textRect.height
            )
        }
    }

    private func rowHeadRect(for row: DOMTreeTextView.Line) -> CGRect? {
        if row.hasDisclosure {
            return disclosureHitRect(for: row)
        }
        return markupStartRect(for: row) ?? contentRowRects(for: row).first
    }

    private func markupStartRect(for row: DOMTreeTextView.Line) -> CGRect? {
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

    private func isDisclosureHit(at point: CGPoint, in row: DOMTreeTextView.Line) -> Bool {
        guard let hitRect = disclosureHitRect(for: row) else {
            return false
        }
        return hitRect.contains(point)
    }

    private func disclosureHitRect(for row: DOMTreeTextView.Line) -> CGRect? {
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

    private func disclosureAttachmentRange(for row: DOMTreeTextView.Line) -> NSRange {
        NSRange(location: row.textRange.location + row.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth, length: 1)
    }

    private func disclosureSlotRange(for row: DOMTreeTextView.Line) -> NSRange {
        NSRange(
            location: row.textRange.location + row.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth,
            length: DOMTreeTextView.IndentMetrics.disclosureSlotSpaces
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
            : DOMTreeTextView.HighlightTheme.webInspector.hoverRowBackground.resolvedColor(with: traitCollection).cgColor
        let selectedColor = selectedRects.isEmpty && multiSelectedRects.isEmpty
            ? nil
            : DOMTreeTextView.HighlightTheme.webInspector.selectedRowBackground.resolvedColor(with: traitCollection).cgColor
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
        guard let selectedNodeID = selectionRevealState.pendingSelectedNodeID,
              !renderedRowsBuildCoordinator.hasCurrentBuild,
              let row = renderedRows.row(for: selectedNodeID),
              bounds.width > 0,
              bounds.height > 0
        else {
            return
        }

        let rowRect = modelContentRowRect(for: row)
        let headRect = modelRowHeadRect(for: row)
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
        selectionRevealState.consumePendingSelection()
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

    private func row(containingTextOffset offset: Int) -> DOMTreeTextView.Line? {
        let offset = clampedTextOffset(offset)
        return rows.first { row in
            offset >= row.textRange.location && offset <= NSMaxRange(row.textRange)
        }
    }
}

#if DEBUG
extension DOMTreeTextView {
    struct LineSnapshot {
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

    var textStorageBaseForegroundColorForTesting: UIColor? {
        baseTextAttributes()[.foregroundColor] as? UIColor
    }

    func textStorageForegroundColorForTesting(containing text: String) -> UIColor? {
        let range = (unsafe textStorage.string as NSString).range(of: text)
        guard range.location != NSNotFound,
              range.location < textStorage.length
        else {
            return nil
        }
        return unsafe textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }

    func tokenForegroundColorForTesting(kind: String) -> UIColor? {
        guard let tokenKind = DOMTreeTextView.Token.Kind(rawValue: kind) else {
            return nil
        }
        return resolvedTextAttributes().tokenColors[tokenKind]
    }

    var documentObservationDeliveryForTesting: PortableObservationTracking.Token {
        documentObservation!
    }

    var selectionObservationDeliveryForTesting: PortableObservationTracking.Token {
        selectionObservation!
    }

    var rowCountForTesting: Int {
        rows.count
    }

    var renderedLineSnapshotsForTesting: [LineSnapshot] {
        rows.map { row in
            let line = row.text as NSString
            return LineSnapshot(
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
        renderedRows.removeRowIndex(for: row.nodeID)
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
        performanceCounters.reloadTreeCallCount
    }

    var buildRenderedRowsCallCountForTesting: Int {
        performanceCounters.buildRenderedRowsCallCount
    }

    var rebuildTextStorageCallCountForTesting: Int {
        performanceCounters.rebuildTextStorageCallCount
    }

    var incrementalTextStorageEditCallCountForTesting: Int {
        performanceCounters.incrementalTextStorageEditCallCount
    }

    var resetTextFragmentViewsCallCountForTesting: Int {
        performanceCounters.resetTextFragmentViewsCallCount
    }

    func resetPerformanceCountersForTesting() {
        performanceCounters.reset()
    }

    var findFoundRangesForTesting: [NSRange] {
        findDecorationState.foundRanges
    }

    var findHighlightedRangesForTesting: [NSRange] {
        findDecorationState.highlightedRanges
    }

    func selectRowForTesting(containing text: String) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        select(row.nodeID)
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
            clearMultiSelection(keepingLast: row.nodeID)
            select(row.nodeID)
        }
    }

    func hoverRowForTesting(containing text: String) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        hover(row: row)
    }

    func endHoverForTesting() {
        clearHoveredRowAndRestoreSelectionHighlight()
    }

    func decorateFindTextForTesting(query: String) {
        clearFindDecorations()
        for range in DOMTreeTextView.FindCoordinator.searchRanges(in: renderedText, queryString: query) {
            decorateFindTextRange(range, style: .found)
        }
        if let firstRange = DOMTreeTextView.FindCoordinator.searchRanges(in: renderedText, queryString: query).first {
            decorateFindTextRange(firstRange, style: .highlighted)
        }
    }

    func decorateStaleFindTextForTesting(query: String) {
        findCoordinator.decorateStaleFoundTextForTesting(queryString: query)
    }

    func synchronizeDocumentForTesting() async {
        reloadTree(resetFragments: true)
        await waitForRenderedRowsForTesting()
    }

    func waitForRenderedRowsForTesting() async {
        await renderedRowsBuildCoordinator.waitForCurrentBuild()
    }

    func suspendNextRenderedRowsBuildForTesting() {
        renderedRowsBuildCoordinator.suspendNextBuildForTesting()
    }

    func waitForRenderedRowsBuildSuspensionForTesting() async {
        await renderedRowsBuildCoordinator.waitForBuildSuspensionForTesting()
    }

    func resumeRenderedRowsBuildForTesting() {
        renderedRowsBuildCoordinator.resumeSuspendedBuildForTesting()
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
        guard let tokenKind = DOMTreeTextView.Token.Kind(rawValue: kind) else {
            return nil
        }
        return tokenKind.color(resolvedFor: UITraitCollection(userInterfaceStyle: style))
    }

    static func selectedRowBackgroundColorForTesting(style: UIUserInterfaceStyle) -> UIColor {
        DOMTreeTextView.HighlightTheme.webInspector.selectedRowBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
    }

    static func disclosureColorForTesting(style: UIUserInterfaceStyle) -> UIColor {
        DOMTreeTextView.HighlightTheme.webInspector.disclosure.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
    }
}

@MainActor
private final class DOMTreeTextViewportLayoutDelegate: NSObject, @preconcurrency NSTextViewportLayoutControllerDelegate {
    private weak var textView: DOMTreeTextView?

    init(textView: DOMTreeTextView) {
        self.textView = textView
        super.init()
    }

    // TextKit2 invokes this delegate from the UIKit main-thread layout pipeline,
    // but the imported delegate protocol is not annotated with MainActor isolation.
    func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        textView?.viewportBounds(for: textViewportLayoutController) ?? .zero
    }

    func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        textView?.textViewportLayoutControllerWillLayout(textViewportLayoutController)
    }

    func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        textView?.textViewportLayoutController(
            textViewportLayoutController,
            configureRenderingSurfaceFor: textLayoutFragment
        )
    }

    func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        textView?.textViewportLayoutControllerDidLayout(textViewportLayoutController)
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

#endif
