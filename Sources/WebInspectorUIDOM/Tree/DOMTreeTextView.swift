#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import Observation
import ObservationBridge
import UIHostingMenu
import UIKit

@MainActor
final class DOMTreeTextView: UIScrollView, UITextInput, UITextInteractionDelegate {
    typealias RequestChildrenAction = @MainActor (DOMNode.ID) async -> Bool
    typealias HighlightNodeAction = @MainActor (DOMNode.ID, DOMTreePageHighlightOwner) async throws -> Void
    typealias RestoreHighlightAction = @MainActor () async throws -> Void
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
    private let context: WebInspectorContext
    private let treeController: DOMTreeController
    private var currentTreeSnapshot: DOMTreeSnapshot
    private var selectionRevision: UInt64
    private let menuModel: DOMTreeMenuModel
    private var treeTransactionTask: Task<Void, Never>?
    private let textDocument = DOMTreeTextDocument()
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

    private var rows: [DOMTreeRowRenderPlan] {
        textDocument.rowIndex.rows
    }

    private var rowIndex: DOMTreeRowIndex {
        textDocument.rowIndex
    }
    private let expansionState: DOMTreeTextView.ExpansionState
    private let rowRenderBuildCoordinator: DOMTreeTextView.RowRenderBuildCoordinator
    private var hoveredNodeID: DOMNode.ID?
    private var pageHighlightTask: Task<Void, Never>?
    private var pageHighlightIntent: PageHighlightIntent?
    private var requestedChildNodeIDs: Set<DOMNode.ID> = []
    private let findDecorationState = DOMTreeTextView.FindDecorationState()
    private var hoverRowRects: [CGRect] = []
    private var selectedRowRects: [CGRect] = []
    private var multiSelectedRowRects: [CGRect] = []
    private var measuredTextWidth: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var lastRenderedDocumentRootID: DOMNode.ID?
    private var lastRoutedTreeRevision: UInt64?
    private var pendingDOMTreeRenderInvalidation: DOMTreeRenderInvalidation?
    private var pendingDOMTreeRenderInvalidationIsInitial = false
    private var pendingDOMTreeRenderInvalidationRequiresRoute = false
    private var domTreeRenderInvalidationTask: Task<Void, Never>?
    private var lastObservedTreeContent: DOMTreeTextView.ObservedContent?
    private var lastRoutedSelectedNodeID: DOMNode.ID?
    private var isRenderingActive = false
    private var selectionReconciliationState = SelectionReconciliationState()
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
    private var rowDocumentAppliedTreeRevisionForTestingStorage: UInt64 = 0
    private var rowDocumentAppliedTreeRevisionWaitersForTesting: [UInt64: RowDocumentAppliedTreeRevisionWaiter] = [:]
    private var nextRowDocumentAppliedTreeRevisionWaiterIDForTesting: UInt64 = 0
#endif

    private var textContentStorage: NSTextContentStorage {
        textDocument.textContentStorage
    }

    private var layoutManager: NSTextLayoutManager {
        textDocument.layoutManager
    }

    private var textContainer: NSTextContainer {
        textDocument.textContainer
    }

    var documentTextForFind: String {
        textDocument.string
    }

    private var documentText: String {
        textDocument.string
    }

    private var rowHeight: CGFloat {
        Self.paragraphLineHeight
    }

    private enum PageHighlightReason: Equatable {
        case selection
        case hover

        var owner: DOMTreePageHighlightOwner {
            switch self {
            case .selection:
                .selection
            case .hover:
                .transient
            }
        }
    }

    private enum PageHighlightIntent: Equatable {
        case selection(DOMNode.ID)
        case restoreSelectionAfterHover
    }

    private struct SelectionReconciliationState {
        private var lastReconciledSelectionRevision: UInt64?
        private(set) var pendingSelectionRevision: UInt64?

        mutating func recordSelectionObservation(revision: UInt64) {
            pendingSelectionRevision = max(pendingSelectionRevision ?? revision, revision)
        }

        func needsReconcile(currentRevision: UInt64) -> Bool {
            guard let lastReconciledSelectionRevision else {
                return true
            }
            return currentRevision != lastReconciledSelectionRevision
        }

        mutating func markReconciled(revision: UInt64) {
            lastReconciledSelectionRevision = revision
            if let pendingSelectionRevision,
               pendingSelectionRevision <= revision {
                self.pendingSelectionRevision = nil
            }
        }
    }

#if DEBUG
    private struct RowDocumentAppliedTreeRevisionWaiter {
        var minimumRevision: UInt64
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }
#endif

    init(
        context: WebInspectorContext,
        requestChildrenAction: RequestChildrenAction? = nil,
        highlightNodeAction: HighlightNodeAction? = nil,
        restoreHighlightAction: RestoreHighlightAction? = nil,
        copyNodeTextAction: CopyNodeTextAction? = nil,
        deleteNodesAction: DeleteNodesAction? = nil
    ) {
        self.context = context
        let treeController = context.dom.treeController()
        self.treeController = treeController
        self.currentTreeSnapshot = treeController.snapshot
        self.selectionRevision = currentTreeSnapshot.revision
        self.requestChildrenAction = requestChildrenAction
        self.highlightNodeAction = highlightNodeAction
        self.restoreHighlightAction = restoreHighlightAction
        let expansionState = DOMTreeTextView.ExpansionState()
        self.expansionState = expansionState
        self.rowRenderBuildCoordinator = DOMTreeTextView.RowRenderBuildCoordinator(
            builder: DOMTreeTextView.RowRenderBuilder(treeController: treeController, expansionState: expansionState)
        )
        self.menuModel = DOMTreeMenuModel(
            context: context,
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
        domTreeRenderInvalidationTask?.cancel()
        treeTransactionTask?.cancel()
        rowRenderBuildCoordinator.cancel()
#if DEBUG
        cancelRowDocumentAppliedTreeRevisionWaitersForTesting()
#endif
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: String(localized: "dom.tree.extend_selection_up", bundle: WebInspectorUILocalization.bundle),
                action: #selector(extendMultiSelectionUp),
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: .shift,
                discoverabilityTitle: String(localized: "dom.tree.extend_selection_up", bundle: WebInspectorUILocalization.bundle)
            ),
            UIKeyCommand(
                title: String(localized: "dom.tree.extend_selection_down", bundle: WebInspectorUILocalization.bundle),
                action: #selector(extendMultiSelectionDown),
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: .shift,
                discoverabilityTitle: String(localized: "dom.tree.extend_selection_down", bundle: WebInspectorUILocalization.bundle)
            ),
            UIKeyCommand(
                title: String(localized: "dom.tree.select_all", bundle: WebInspectorUILocalization.bundle),
                action: #selector(selectAllRowRender),
                input: "a",
                modifierFlags: .command,
                discoverabilityTitle: String(localized: "dom.tree.select_all", bundle: WebInspectorUILocalization.bundle)
            ),
            UIKeyCommand(
                title: String(localized: "dom.tree.find", bundle: WebInspectorUILocalization.bundle),
                action: #selector(showFindNavigator),
                input: "f",
                modifierFlags: .command,
                discoverabilityTitle: String(localized: "dom.tree.find", bundle: WebInspectorUILocalization.bundle)
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
        handlePrimaryClick(at: location, modifiers: recognizer.modifierFlags)
    }

    private func handlePrimaryClick(at location: CGPoint, modifiers: UIKeyModifierFlags = []) {
        guard let row = row(at: location) else {
            return
        }
        let disclosureHit = isDisclosureHit(at: location, in: row)

        dismissDOMMenuAnchor()
        clearTextSelection()
        if disclosureHit {
            toggle(row: row)
        } else if modifiers.contains(.shift) {
            extendMultiSelection(to: row)
        } else if modifiers.contains(.command) || modifiers.contains(.control) {
            toggleMultiSelection(row: row)
        } else if select(row.nodeID) {
            clearMultiSelection(keepingLast: row.nodeID)
        }
    }

    func setRenderingActive(_ isActive: Bool) {
        guard isRenderingActive != isActive else {
            if isActive {
                flushPendingSelectionInvalidationIfNeeded()
                reconcileCurrentDOMInvalidationForActiveRendering()
                flushPendingDOMInvalidationIfNeeded()
            }
            return
        }

        isRenderingActive = isActive
        if isActive {
            flushPendingSelectionInvalidationIfNeeded()
            reconcileCurrentDOMInvalidationForActiveRendering()
            flushPendingDOMInvalidationIfNeeded()
        } else {
            suspendRenderingWork()
        }
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let row = row(at: recognizer.location(in: textContentView))
        else {
            return
        }

        let nodeIDs: [DOMNode.ID]
        if multiSelection.selectedCount > 1, multiSelection.contains(row.nodeID) {
            nodeIDs = multiSelectedNodeIDsInDisplayOrder()
        } else {
            guard (try? context.requiredNode(for: row.nodeID)) != nil,
                  select(row.nodeID) else {
                return
            }
            nodeIDs = [row.nodeID]
        }
        presentDOMMenu(for: nodeIDs, at: recognizer.location(in: self))
    }

    @objc private func extendMultiSelectionUp() {
        extendMultiSelectionByKeyboard(delta: -1)
    }

    @objc private func extendMultiSelectionDown() {
        extendMultiSelectionByKeyboard(delta: 1)
    }

    @objc private func selectAllRowRender() {
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
        let length = (documentText as NSString).length
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

        layoutManager.textViewportLayoutController.delegate = viewportLayoutDelegate

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
        treeTransactionTask = Task { @MainActor [weak self, treeController] in
            for await update in treeController.updates {
                guard let self else {
                    return
                }
                let previousSnapshot = currentTreeSnapshot
                let invalidation: DOMTreeRenderInvalidation
                let isSelectionChange: Bool
                let isInitial: Bool
                switch update {
                case let .snapshot(snapshot, reason):
                    currentTreeSnapshot = snapshot
                    invalidation = .snapshot(snapshot, reason: reason)
                    isSelectionChange = previousSnapshot.selectedNodeID != snapshot.selectedNodeID
                    isInitial = reason == .initialDocument && lastRoutedTreeRevision == nil
                case let .delta(delta):
                    let currentRevision = treeController.revision
                    let currentSelectedNodeID = treeController.selectedNodeID
                    invalidation = DOMTreeRenderInvalidation(
                        delta: delta,
                        revision: currentRevision,
                        startRevision: previousSnapshot.revision
                    )
                    isSelectionChange = delta.isSelectionChange
                        || previousSnapshot.selectedNodeID != currentSelectedNodeID
                    if isSelectionChange {
                        currentTreeSnapshot = treeController.snapshot
                    }
                    isInitial = false
                }
                if !isSelectionChange || invalidation.kind != .content {
                    scheduleDOMInvalidation(invalidation, isInitial: isInitial)
                }
                if isSelectionChange {
                    selectionRevision = currentTreeSnapshot.revision
                    routeSelectionInvalidation(selectionRevision: selectionRevision)
                }
            }
        }
    }

    private func suspendRenderingWork() {
        let hadCurrentRowRenderBuild = rowRenderBuildCoordinator.hasCurrentBuild
        let needsHoveredPageHighlightRestore = hoveredNodeID != nil
        domTreeRenderInvalidationTask?.cancel()
        domTreeRenderInvalidationTask = nil
        rowRenderBuildCoordinator.cancel()
        if hadCurrentRowRenderBuild {
            let invalidation = DOMTreeRenderInvalidation.initial(snapshot: currentTreeSnapshot)
            pendingDOMTreeRenderInvalidation = pendingDOMTreeRenderInvalidation?.merging(with: invalidation) ?? invalidation
            pendingDOMTreeRenderInvalidationRequiresRoute = true
        }
        if needsHoveredPageHighlightRestore {
            clearHoveredRowAndRestoreSelectionHighlight()
        } else if pageHighlightIntent == .restoreSelectionAfterHover {
            return
        } else {
            cancelPageHighlightTask(preservingIntent: true)
        }
    }

    private func reconcileCurrentDOMInvalidationForActiveRendering() {
        guard isRenderingActive else {
            return
        }
        synchronizeCurrentTreeSnapshotIfNeeded()

        let latestInvalidation = DOMTreeRenderInvalidation.initial(snapshot: currentTreeSnapshot)
        let treeRevision = latestInvalidation.revision
        let previousRoutedTreeRevision = lastRoutedTreeRevision
        guard previousRoutedTreeRevision != treeRevision else {
            return
        }

        lastRoutedTreeRevision = treeRevision
        scheduleDOMInvalidation(latestInvalidation, isInitial: previousRoutedTreeRevision == nil)
    }

    private func scheduleDOMInvalidation(
        _ invalidation: DOMTreeRenderInvalidation,
        isInitial: Bool,
        forceRoute: Bool = false
    ) {
        pendingDOMTreeRenderInvalidation = pendingDOMTreeRenderInvalidation?.merging(with: invalidation) ?? invalidation
        pendingDOMTreeRenderInvalidationIsInitial = pendingDOMTreeRenderInvalidationIsInitial || isInitial
        pendingDOMTreeRenderInvalidationRequiresRoute = pendingDOMTreeRenderInvalidationRequiresRoute
            || forceRoute
            || shouldRouteDOMInvalidation(invalidation, isInitial: isInitial)
            || rowRenderBuildCoordinator.currentBuildMayRender(invalidation)
        guard isRenderingActive else {
            return
        }
        schedulePendingDOMInvalidationFlush()
    }

    private func schedulePendingDOMInvalidationFlush() {
        guard isRenderingActive,
              domTreeRenderInvalidationTask == nil else {
            return
        }
        domTreeRenderInvalidationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else {
                return
            }
            domTreeRenderInvalidationTask = nil
            flushPendingDOMInvalidationIfNeeded()
        }
    }

    private func flushPendingDOMInvalidationIfNeeded() {
        guard isRenderingActive else {
            return
        }
        domTreeRenderInvalidationTask?.cancel()
        domTreeRenderInvalidationTask = nil
        let pendingInvalidation = pendingDOMTreeRenderInvalidation
        let pendingIsInitial = pendingDOMTreeRenderInvalidationIsInitial
        let pendingRequiresRoute = pendingDOMTreeRenderInvalidationRequiresRoute
        pendingDOMTreeRenderInvalidation = nil
        pendingDOMTreeRenderInvalidationIsInitial = false
        pendingDOMTreeRenderInvalidationRequiresRoute = false
        guard let pendingInvalidation else {
            return
        }
        synchronizeCurrentTreeSnapshotIfNeeded(for: pendingInvalidation.revision)
        routeDOMInvalidation(
            pendingInvalidation,
            isInitial: pendingIsInitial,
            forceRoute: pendingRequiresRoute
        )
    }

    private func routeDOMInvalidation(
        _ invalidation: DOMTreeRenderInvalidation,
        isInitial: Bool,
        forceRoute: Bool = false
    ) {
        guard isRenderingActive else {
            pendingDOMTreeRenderInvalidation = pendingDOMTreeRenderInvalidation?.merging(with: invalidation) ?? invalidation
            pendingDOMTreeRenderInvalidationIsInitial = pendingDOMTreeRenderInvalidationIsInitial || isInitial
            pendingDOMTreeRenderInvalidationRequiresRoute = pendingDOMTreeRenderInvalidationRequiresRoute || forceRoute
            return
        }
        synchronizeCurrentTreeSnapshotIfNeeded(for: invalidation.revision)
        guard forceRoute || shouldRouteDOMInvalidation(invalidation, isInitial: isInitial) else {
            return
        }
#if DEBUG
        performanceCounters.buildRowRenderPlanCallCount += 1
#endif
        let didResetLocalDocumentState = resetLocalDocumentStateIfNeeded(
            rootID: currentTreeSnapshot.rootNodeID,
            force: invalidation.resetsLocalDocumentState
        )
        prepareSelectionForRendering()
        startRowRenderBuild(
            resetFragments: isInitial || invalidation.requiresFragmentReset || didResetLocalDocumentState,
            previousRows: rows,
            previousText: documentText,
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

    private func synchronizeCurrentTreeSnapshotIfNeeded(for revision: UInt64? = nil) {
        let targetRevision = revision ?? treeController.revision
        guard currentTreeSnapshot.revision < targetRevision else {
            return
        }
        currentTreeSnapshot = treeController.snapshot
    }

    private func shouldRouteDOMInvalidation(
        _ invalidation: DOMTreeRenderInvalidation,
        isInitial: Bool,
        visibleNodeIDs: Set<DOMNode.ID>? = nil
    ) -> Bool {
        guard !isInitial, !invalidation.requiresFragmentReset else {
            return true
        }
        let visibleNodeIDs = visibleNodeIDs ?? rowIndex.visibleNodeIDs

        switch invalidation.kind {
        case .root:
            return true
        case .content:
            guard !invalidation.affectedNodeIDs.isEmpty else {
                return true
            }
            return !invalidation.affectedNodeIDs.isDisjoint(with: visibleNodeIDs)
        case .structure:
            let renderRootNodeID = currentTreeSnapshot.rootNodeID
            if let renderRootNodeID,
               invalidation.affectedNodeIDs.contains(renderRootNodeID)
                || invalidation.parentNodeIDs.contains(renderRootNodeID) {
                return true
            }
            if invalidation.intersects(nodeIDs: visibleNodeIDs) {
                return true
            }
            return !invalidation.hasScopedNodes
        }
    }

    private func routeSelectionInvalidation(selectionRevision: UInt64) {
        guard isRenderingActive else {
            selectionReconciliationState.recordSelectionObservation(revision: selectionRevision)
            return
        }

        let nextSelectedNodeID = currentTreeSnapshot.selectedNodeID
        let shouldReconcileSelection = lastRoutedSelectedNodeID != nextSelectedNodeID
            || selectionReconciliationState.needsReconcile(currentRevision: selectionRevision)
        guard shouldReconcileSelection else {
            revealPendingSelectedNodeIfPossible()
            reconcilePageSelectionHighlightIntentIfNeeded()
            return
        }
        handleSelectedNodeChange(selectionRevision: selectionRevision)
    }

    private func flushPendingSelectionInvalidationIfNeeded() {
        guard isRenderingActive else {
            return
        }
        routeSelectionInvalidation(selectionRevision: selectionRevision)
    }

    private func handleSelectedNodeChange(selectionRevision: UInt64) {
        let previousOpenState = expansionState.snapshot
        prepareSelectionForRendering(clearsMultiSelectionForDocumentSelection: true)
        selectionReconciliationState.markReconciled(revision: selectionRevision)
        if previousOpenState != expansionState.snapshot || selectedNodeNeedsRowReload() {
            reloadTree(resetFragments: false)
            return
        }
        updateContentDecorations()
        revealPendingSelectedNodeIfPossible()
        reconcilePageSelectionHighlightIntentIfNeeded()
    }

    private func reloadTree(resetFragments: Bool, countsCall: Bool = true) {
#if DEBUG
        if countsCall {
            performanceCounters.reloadTreeCallCount += 1
        }
#endif
        startRowDocumentReload(resetFragments: resetFragments, countsCall: false)
    }

    private func startRowDocumentReload(
        resetFragments: Bool,
        countsCall: Bool = true
    ) {
        guard isRenderingActive else {
            let invalidation = DOMTreeRenderInvalidation.initial(snapshot: currentTreeSnapshot)
            pendingDOMTreeRenderInvalidation = pendingDOMTreeRenderInvalidation?.merging(with: invalidation) ?? invalidation
            pendingDOMTreeRenderInvalidationRequiresRoute = true
            return
        }
#if DEBUG
        if countsCall {
            performanceCounters.reloadTreeCallCount += 1
        }
#endif
        let didResetLocalDocumentState = resetLocalDocumentStateIfNeeded()
        let previousRows = rows
        let previousText = documentText
        let shouldResetFragments = resetFragments || didResetLocalDocumentState
        if shouldResetFragments {
            rowRenderBuildCoordinator.removeCachedMarkup(keepingCapacity: true)
        }
        prepareSelectionForRendering()
#if DEBUG
        performanceCounters.buildRowRenderPlanCallCount += 1
#endif
        startRowRenderBuild(
            resetFragments: shouldResetFragments,
            previousRows: previousRows,
            previousText: previousText
        )
    }

    private func startRowRenderBuild(
        resetFragments: Bool,
        previousRows: [DOMTreeRowRenderPlan],
        previousText: String,
        shouldApply: (@MainActor (DOMTreeTextView.RowRenderBuildResult) -> Bool)? = nil
    ) {
        guard isRenderingActive else {
            return
        }
        rowRenderBuildCoordinator.startBuild(
            previousRowCapacity: rows.count,
            previousTextCapacity: documentText.count,
            isCurrentBuild: { [weak self] request, result in
                guard let self else {
                    return false
                }
                guard isRenderingActive else {
                    return false
                }
                guard currentTreeSnapshot.revision == request.treeRevision else {
                    scheduleDOMInvalidation(
                        .initial(snapshot: currentTreeSnapshot),
                        isInitial: false,
                        forceRoute: true
                    )
                    return false
                }
                _ = result
                return expansionState.snapshot == request.expansionState
            },
            shouldApply: shouldApply,
            apply: { [weak self] buildResult in
                guard let self else {
                    return
                }
                guard isRenderingActive else {
                    return
                }
                applyRowRenderBuildResult(
                    buildResult,
                    resetFragments: resetFragments,
                    previousRows: previousRows,
                    previousText: previousText
                )
            },
            didFinish: { [weak self] in
                self?.revealPendingSelectedNodeIfPossible()
                self?.reconcilePageSelectionHighlightIntentIfNeeded()
            }
        )
    }

    private func applyRowRenderBuildResult(
        _ buildResult: DOMTreeTextView.RowRenderBuildResult,
        resetFragments: Bool,
        previousRows: [DOMTreeRowRenderPlan],
        previousText: String
    ) {
        lastObservedTreeContent = buildResult.observedContent
        let nextRows = buildResult.rows
        let nextText = buildResult.text
        if resetFragments {
            resetTextFragmentViews()
            replaceRowDocument(rows: nextRows)
        } else {
            updateRowDocumentIncrementally(
                previousRows: previousRows,
                previousText: previousText,
                nextRows: nextRows,
                nextText: nextText
            )
        }
        rowRenderBuildCoordinator.pruneCachedMarkup(keeping: rowIndex.visibleNodeIDs)
        reconcileMultiSelectionAfterReload()
        clampTextSelectionAfterTextChange()
        maxLineDisplayColumnCount = buildResult.maxLineDisplayColumnCount
        updateMeasuredTextWidth()
        pruneChildRequestState()
        requestChildrenForOpenRowsIfNeeded()

        clearFindDecorations()
        findCoordinator.invalidateResultsAfterTextChange()
        updateTextLayoutGeometry()
        updateContentDecorations()
        setNeedsLayout()
#if DEBUG
        recordRowDocumentAppliedTreeRevisionForTesting(currentTreeSnapshot.revision)
#endif
    }

    @discardableResult
    private func resetLocalDocumentStateIfNeeded(rootID: DOMNode.ID? = nil, force: Bool = false) -> Bool {
        let rootID = rootID ?? currentTreeSnapshot.rootNodeID
        defer {
            lastRenderedDocumentRootID = rootID
        }
        guard force
                || rootID == nil
                || (lastRenderedDocumentRootID != nil && lastRenderedDocumentRootID != rootID) else {
            return false
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
        return true
    }

    private func prepareSelectionForRendering(clearsMultiSelectionForDocumentSelection: Bool = false) {
        let nextSelectedNodeID = currentTreeSnapshot.selectedNodeID
        let selectedNodeIDChanged = lastRoutedSelectedNodeID != nextSelectedNodeID
        lastRoutedSelectedNodeID = nextSelectedNodeID
        let selectedNode = nextSelectedNodeID.flatMap { try? context.requiredNode(for: $0) }
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
        for ancestorID in currentTreeSnapshot.ancestorNodeIDs(of: node.id) {
            guard let ancestor = currentTreeSnapshot.node(for: ancestorID) else {
                continue
            }
            if ancestor.kind != .document || currentTreeSnapshot.parent(of: ancestor.id) != nil {
                expansionState.setIsOpen(true, for: ancestor.id)
            }
        }
    }

    private func updateMeasuredTextWidth() {
        measuredTextWidth = CGFloat(maxLineDisplayColumnCount) * Self.characterWidth
    }

    private func pruneChildRequestState() {
        requestedChildNodeIDs = requestedChildNodeIDs.filter { nodeID in
            hasUnloadedRegularChildren(nodeID)
        }
    }

    private func requestChildrenForOpenRowsIfNeeded() {
        guard isRenderingActive,
              currentTreeSnapshot.rootNodeID != nil else {
            return
        }
        for row in rows where row.hasDisclosure && row.isOpen {
            requestChildrenIfNeeded(for: row.nodeID)
        }
    }

    private func requestChildrenIfNeeded(for nodeID: DOMNode.ID) {
        guard isRenderingActive,
              hasUnloadedRegularChildren(nodeID),
              requestedChildNodeIDs.insert(nodeID).inserted
        else {
            return
        }
        Task { @MainActor [weak self, requestChildrenAction] in
            guard let self else {
                return
            }
            defer {
                self.requestedChildNodeIDs.remove(nodeID)
            }
            _ = await requestChildrenAction?(nodeID) ?? false
        }
    }

    private func hasUnloadedRegularChildren(_ nodeID: DOMNode.ID) -> Bool {
        guard let node = currentTreeSnapshot.node(for: nodeID),
              case let .unrequested(count) = node.children else {
            return false
        }
        return count > 0
    }

    private func toggle(row: DOMTreeRowRenderPlan) {
        expansionState.setIsOpen(!row.isOpen, for: row.nodeID)
        reloadTree(resetFragments: false)
    }

    @discardableResult
    private func select(_ nodeID: DOMNode.ID) -> Bool {
        do {
            try context.dom.select(nodeID, reveal: .selectAndScroll)
        } catch {
            WebInspectorUIDOMLog.debug("DOM tree selection failed nodeID=\(String(describing: nodeID)): \(String(describing: error))")
            return false
        }
        multiSelection.notePrimarySelection(nodeID)
        currentTreeSnapshot = treeController.snapshot
        selectionRevision = currentTreeSnapshot.revision
        if isRenderingActive {
            handleSelectedNodeChange(selectionRevision: selectionRevision)
        } else {
            selectionReconciliationState.recordSelectionObservation(revision: selectionRevision)
        }
        queuePageSelectionHighlight(for: nodeID)
        return true
    }

    private func toggleMultiSelection(row: DOMTreeRowRenderPlan) {
        multiSelection.toggle(
            row: row,
            rowIndex: rowIndex,
            selectedNodeID: currentTreeSnapshot.selectedNodeID
        )
        updateContentDecorations()
    }

    private func extendMultiSelection(to row: DOMTreeRowRenderPlan) {
        if multiSelection.extend(
            to: row,
            rowIndex: rowIndex,
            selectedNodeID: currentTreeSnapshot.selectedNodeID
        ) {
            updateContentDecorations()
        }
    }

    private func extendMultiSelectionByKeyboard(delta: Int) {
        guard !rows.isEmpty else {
            return
        }

        let focusedNodeID = multiSelection.focusedNodeID(
            selectedNodeID: currentTreeSnapshot.selectedNodeID,
            fallbackNodeID: rows.first?.nodeID
        )
        guard let focusedNodeID,
              let focusedIndex = rowIndex.rowIndex(for: focusedNodeID)
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
        multiSelection.reconcileAfterReload(visibleNodeIDs: rowIndex.visibleNodeIDs)
    }

    private func multiSelectedNodeIDsInDisplayOrder() -> [DOMNode.ID] {
        multiSelection.selectedNodeIDsInDisplayOrder(rowIndex: rowIndex).filter {
            (try? context.requiredNode(for: $0)) != nil
        }
    }

    private func scrollRowToVisible(_ row: DOMTreeRowRenderPlan) {
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

    private func modelContentRowRect(for row: DOMTreeRowRenderPlan) -> CGRect {
        // DOM tree rows are fixed-height; reveal must not depend on TextKit fragment rects while layout catches up.
        CGRect(
            x: 0,
            y: CGFloat(row.rowIndex) * rowHeight,
            width: max(textContentView.bounds.width, contentSize.width - Self.textInsets.left - Self.textInsets.right),
            height: rowHeight
        )
    }

    private func modelRowHeadRect(for row: DOMTreeRowRenderPlan) -> CGRect {
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

    private func row(at location: CGPoint) -> DOMTreeRowRenderPlan? {
        guard location.y >= 0 else {
            return nil
        }
        layoutManager.ensureLayout(for: visibleTextRect(horizontalPadding: 0))
        if let layoutFragment = layoutManager.textLayoutFragment(for: location),
           layoutFragment.layoutFragmentFrame.minY <= location.y,
           location.y < layoutFragment.layoutFragmentFrame.maxY,
           let row = textDocument.row(for: layoutFragment) {
            return row
        }
        return modelRow(at: location)
    }

    private func modelRow(at location: CGPoint) -> DOMTreeRowRenderPlan? {
        let index = Int(floor(location.y / rowHeight))
        guard rows.indices.contains(index) else {
            return nil
        }
        return rows[index]
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

    private func hover(row: DOMTreeRowRenderPlan) {
        if hoveredNodeID != row.nodeID {
            hoveredNodeID = row.nodeID
            updateContentDecorations()
        }
        highlightPageNode(row.nodeID, reason: .hover)
    }

    private func queuePageSelectionHighlight(for nodeID: DOMNode.ID) {
        pageHighlightIntent = .selection(nodeID)
        reconcilePageSelectionHighlightIntentIfNeeded()
    }

    private func reconcilePageSelectionHighlightIntentIfNeeded() {
        guard case .selection(let nodeID) = pageHighlightIntent,
              currentTreeSnapshot.selectedNodeID == nodeID else {
            return
        }
        highlightPageNode(nodeID, reason: .selection)
    }

    private func highlightPageNode(_ nodeID: DOMNode.ID, reason: PageHighlightReason) {
        guard isRenderingActive else {
            return
        }
        switch reason {
        case .selection:
            pageHighlightIntent = .selection(nodeID)
            cancelPageHighlightTask(preservingIntent: true)
        case .hover:
            cancelPageHighlightTask()
        }
        pageHighlightTask = Task { @MainActor [weak self, highlightNodeAction] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self else {
                return
            }
            switch reason {
            case .selection:
                guard self.currentTreeSnapshot.selectedNodeID == nodeID else {
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
            do {
                if let highlightNodeAction {
                    try await highlightNodeAction(nodeID, reason.owner)
                }
                if reason == .selection,
                   self.pageHighlightIntent == .selection(nodeID) {
                    self.pageHighlightIntent = nil
                }
            } catch {
                WebInspectorUIDOMLog.debug(
                    "DOM tree page highlight failed nodeID=\(String(describing: nodeID)) owner=\(reason.owner): \(String(describing: error))"
                )
            }
        }
    }

    private func clearHoveredRowAndRestoreSelectionHighlight() {
        cancelPageHighlightTask()
        clearHoveredRow()
        pageHighlightIntent = .restoreSelectionAfterHover
        pageHighlightTask = Task { @MainActor [weak self, restoreHighlightAction] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self else {
                return
            }
            guard self.hoveredNodeID == nil else {
                if self.pageHighlightIntent == .restoreSelectionAfterHover {
                    self.pageHighlightIntent = nil
                }
                return
            }
            do {
                if let restoreHighlightAction {
                    try await restoreHighlightAction()
                }
                if self.pageHighlightIntent == .restoreSelectionAfterHover {
                    self.pageHighlightIntent = nil
                }
            } catch {
                WebInspectorUIDOMLog.debug("DOM tree page highlight restore failed: \(String(describing: error))")
            }
        }
    }

    private func cancelPageHighlightTask(preservingIntent: Bool = false) {
        pageHighlightTask?.cancel()
        pageHighlightTask = nil
        if !preservingIntent {
            pageHighlightIntent = nil
        }
    }

    private func presentDOMMenu(for nodeIDs: [DOMNode.ID], at location: CGPoint) {
        let menu = makeDOMMenu(for: nodeIDs)

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

    private func makeDOMMenu(for nodeIDs: [DOMNode.ID], selectedText: String? = nil) -> UIMenu {
        makeMenu(
            for: uniqueNodeIDsInDisplayOrder(for: nodeIDs),
            selectedText: selectedText
        )
    }

    private func makeTextSelectionEditMenu(for range: NSRange) -> UIMenu {
        let selectedRows = rowsIntersectingTextRange(range)
        let nodeIDs = uniqueNodeIDsInDisplayOrder(for: selectedRows)
        guard !nodeIDs.isEmpty else {
            return UIMenu(children: [])
        }
        let selectedText = selectedRows.count == 1 ? text(in: DOMTreeTextRange(range: range)) : nil
        return makeDOMMenu(for: nodeIDs, selectedText: selectedText)
    }

    private func rowsIntersectingTextRange(_ range: NSRange) -> [DOMTreeRowRenderPlan] {
        let range = clampedTextRange(range)
        guard range.length > 0 else {
            return []
        }
        let lowerBound = range.location
        let upperBound = NSMaxRange(range)
        var lowerIndex = 0
        var upperIndex = rows.count
        while lowerIndex < upperIndex {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if NSMaxRange(rows[middleIndex].documentRange) <= lowerBound {
                lowerIndex = middleIndex + 1
            } else {
                upperIndex = middleIndex
            }
        }

        var result: [DOMTreeRowRenderPlan] = []
        var index = lowerIndex
        while rows.indices.contains(index) {
            let row = rows[index]
            guard row.documentRange.location < upperBound else {
                break
            }
            if lowerBound < NSMaxRange(row.documentRange) {
                result.append(row)
            }
            index += 1
        }
        return result
    }

    private func uniqueNodeIDsInDisplayOrder(for rows: [DOMTreeRowRenderPlan]) -> [DOMNode.ID] {
        var seenNodeIDs: Set<DOMNode.ID> = []
        return rows.compactMap { row in
            seenNodeIDs.insert(row.nodeID).inserted && (try? context.requiredNode(for: row.nodeID)) != nil ? row.nodeID : nil
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
        rowIndex.row(for: nodeID)?.text
    }

    private func uniqueNodeIDsInDisplayOrder(for nodeIDs: [DOMNode.ID]) -> [DOMNode.ID] {
        var seenNodeIDs: Set<DOMNode.ID> = []
        return nodeIDs.compactMap { nodeID in
            seenNodeIDs.insert(nodeID).inserted ? nodeID : nil
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

    private func reapplyTextAttributes() {
        replaceRowDocument(rows: rows)
        setNeedsDisplayForVisibleTextFragments()
    }

    private func replaceRowDocument(rows: [DOMTreeRowRenderPlan]) {
#if DEBUG
        performanceCounters.replaceRowDocumentCallCount += 1
#endif
        textDocument.replaceDocument(
            with: attributedDocumentText(for: rows),
            rows: rows
        )
        invalidateTextLayout()
    }

    private func updateRowDocumentIncrementally(
        previousRows: [DOMTreeRowRenderPlan],
        previousText: String,
        nextRows: [DOMTreeRowRenderPlan],
        nextText: String
    ) {
        guard !previousText.isEmpty, !nextText.isEmpty else {
            replaceRowDocument(rows: nextRows)
            return
        }
        guard let diff = rowDiff(previousRows: previousRows, nextRows: nextRows) else {
            textDocument.replaceDocument(
                with: attributedDocumentText(for: nextRows),
                rows: nextRows
            )
            return
        }

        let edit = textEdit(
            previousRows: previousRows,
            previousText: previousText,
            nextRows: nextRows,
            diff: diff
        )
        let replacement = attributedReplacementText(nextRows: nextRows, diff: diff)
        textDocument.replaceCharacters(in: edit.range, with: replacement, rows: nextRows)
#if DEBUG
        performanceCounters.incrementalRowDocumentEditCallCount += 1
#endif

        let editedLength = max(edit.range.length, replacement.length)
        invalidateTextLayout(for: NSRange(location: edit.range.location, length: editedLength))
        let changedRows = Array(nextRows[diff.nextStart..<diff.nextEnd])
        if edit.range.length > 0 || replacement.length > 0 {
            setNeedsDisplayForTextRanges(changedRows.map(\.documentRange))
        }
    }

    private func rowDiff(
        previousRows: [DOMTreeRowRenderPlan],
        nextRows: [DOMTreeRowRenderPlan]
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
        previousRows: [DOMTreeRowRenderPlan],
        previousText: String,
        nextRows: [DOMTreeRowRenderPlan],
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
                length = previousRows[diff.previousEnd].documentRange.location
            }
        } else {
            let previousRow = previousRows[diff.previousStart - 1]
            location = previousRow.documentRange.location + previousRow.documentRange.length
            if diff.previousEnd == previousRows.count {
                length = previousLength - location
            } else {
                length = previousRows[diff.previousEnd].documentRange.location - location
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

    private func attributedDocumentText(for rows: [DOMTreeRowRenderPlan]) -> NSAttributedString {
        guard !rows.isEmpty else {
            return NSAttributedString(string: "\n", attributes: baseTextAttributes())
        }
        let attributedText = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            if index > 0 {
                attributedText.append(NSAttributedString(string: "\n", attributes: baseTextAttributes()))
            }
            attributedText.append(attributedRowText(for: row))
        }
        return attributedText
    }

    private func attributedReplacementText(
        nextRows: [DOMTreeRowRenderPlan],
        diff: DOMTreeTextView.RowDiff
    ) -> NSAttributedString {
        let replacementRows = Array(nextRows[diff.nextStart..<diff.nextEnd])
        let attributedText = NSMutableAttributedString()
        if diff.nextStart > 0, !replacementRows.isEmpty {
            attributedText.append(NSAttributedString(string: "\n", attributes: baseTextAttributes()))
        }
        for (index, row) in replacementRows.enumerated() {
            if index > 0 {
                attributedText.append(NSAttributedString(string: "\n", attributes: baseTextAttributes()))
            }
            attributedText.append(attributedRowText(for: row))
        }
        if diff.nextEnd < nextRows.count, !replacementRows.isEmpty {
            attributedText.append(NSAttributedString(string: "\n", attributes: baseTextAttributes()))
        } else if replacementRows.isEmpty, diff.nextStart > 0, diff.nextEnd < nextRows.count {
            attributedText.append(NSAttributedString(string: "\n", attributes: baseTextAttributes()))
        }
        return attributedText
    }

    private func attributedRowText(for row: DOMTreeRowRenderPlan) -> NSAttributedString {
        let resolvedAttributes = resolvedTextAttributes()
        let fallbackColor = resolvedAttributes.tokenColors[.fallback]
            ?? DOMTreeTextView.HighlightTheme.webInspector.textSecondary.resolvedColor(with: traitCollection)
        var attributes = resolvedAttributes.base
        attributes[.foregroundColor] = fallbackColor
        attributes[DOMTreeTextDocument.rowIdentityAttribute] = row.identity

        let attributedRow = NSMutableAttributedString(string: row.text, attributes: attributes)
        for token in row.tokens {
            guard token.range.length > 0,
                  NSMaxRange(token.range) <= attributedRow.length else {
                continue
            }
            attributedRow.addAttribute(
                .foregroundColor,
                value: resolvedAttributes.tokenColors[token.kind] ?? fallbackColor,
                range: token.range
            )
        }
        if row.hasDisclosure {
            let localDisclosureRange = NSRange(
                location: row.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth,
                length: 1
            )
            guard NSMaxRange(localDisclosureRange) <= attributedRow.length else {
                return attributedRow
            }
            let attachment = disclosureAttachmentString(isOpen: row.isOpen)
            attributedRow.replaceCharacters(in: localDisclosureRange, with: attachment)
            attributedRow.addAttribute(
                DOMTreeTextDocument.rowIdentityAttribute,
                value: row.identity,
                range: NSRange(location: localDisclosureRange.location, length: attachment.length)
            )
        }
        return attributedRow
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

    private func invalidateTextLayout(for range: NSRange) {
        guard range.length > 0,
              let textRange = textRange(for: range) else {
            return
        }
        layoutManager.invalidateLayout(for: textRange)
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
        guard let selectedNodeID = currentTreeSnapshot.selectedNodeID else {
            return []
        }
        return rowRects(for: selectedNodeID)
    }

    private func selectedNodeNeedsRowReload() -> Bool {
        guard let selectedNodeID = currentTreeSnapshot.selectedNodeID else {
            return false
        }
        return !rowIndex.contains(nodeID: selectedNodeID)
    }

    private func multiSelectionContentRowRects() -> [CGRect] {
        multiSelection.selectedRowsInDisplayOrder(rowIndex: rowIndex).flatMap(contentRowRects(for:))
    }

    private func hoverContentRowRects() -> [CGRect] {
        guard let hoveredNodeID else {
            return []
        }
        return rowRects(for: hoveredNodeID)
    }

    private func rowRects(for nodeID: DOMNode.ID) -> [CGRect] {
        guard let row = rowIndex.row(for: nodeID) else {
            return []
        }
        return contentRowRects(for: row)
    }

    private func contentRowRects(for row: DOMTreeRowRenderPlan) -> [CGRect] {
        [modelContentRowRect(for: row)]
    }

    private func rowHeadRect(for row: DOMTreeRowRenderPlan) -> CGRect? {
        if row.hasDisclosure {
            return disclosureHitRect(for: row)
        }
        return markupStartRect(for: row) ?? contentRowRects(for: row).first
    }

    private func markupStartRect(for row: DOMTreeRowRenderPlan) -> CGRect? {
        let markupLength = min(1, row.markupRange.length)
        guard markupLength > 0 else {
            return nil
        }
        let column = row.markupRange.location
        return CGRect(
            x: CGFloat(column) * Self.characterWidth,
            y: CGFloat(row.rowIndex) * rowHeight,
            width: Self.characterWidth,
            height: rowHeight
        )
    }

    private func isDisclosureHit(at point: CGPoint, in row: DOMTreeRowRenderPlan) -> Bool {
        guard let hitRect = disclosureHitRect(at: point, in: row) else {
            return false
        }
        return hitRect.contains(point)
    }

    private func disclosureHitRect(at point: CGPoint, in row: DOMTreeRowRenderPlan) -> CGRect? {
        guard row.hasDisclosure else {
            return nil
        }
        layoutManager.ensureLayout(for: visibleTextRect(horizontalPadding: 0))
        guard let layoutFragment = layoutManager.textLayoutFragment(for: point),
              textDocument.row(for: layoutFragment)?.identity == row.identity else {
            return disclosureHitRect(for: row)
        }
        let modelHeadRect = modelRowHeadRect(for: row)
        return CGRect(
            x: modelHeadRect.minX,
            y: layoutFragment.layoutFragmentFrame.minY,
            width: modelHeadRect.width,
            height: layoutFragment.layoutFragmentFrame.height
        )
    }

    private func disclosureHitRect(for row: DOMTreeRowRenderPlan) -> CGRect? {
        guard row.hasDisclosure else {
            return nil
        }
        return modelRowHeadRect(for: row)
    }

    private func disclosureAttachmentRange(for row: DOMTreeRowRenderPlan) -> NSRange {
        NSRange(location: row.documentRange.location + row.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth, length: 1)
    }

    private func disclosureSlotRange(for row: DOMTreeRowRenderPlan) -> NSRange {
        NSRange(
            location: row.documentRange.location + row.depth * DOMTreeTextView.IndentMetrics.indentSpacesPerDepth,
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
        #if DEBUG
        performanceCounters.textSegmentRectsCallCount += 1
        #endif

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
        let fragmentRow = textDocument.row(for: fragmentView.layoutFragment)
        let hoverRects = localRowBackgroundRects(for: fragmentRow, in: surfaceFrame, matching: hoveredNodeID)
        let selectedRects = localRowBackgroundRects(
            for: fragmentRow,
            in: surfaceFrame,
            matching: currentTreeSnapshot.selectedNodeID
        )
        let multiSelectedRects = localMultiSelectedRowBackgroundRects(for: fragmentRow, in: surfaceFrame)
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

    private func localRowBackgroundRects(
        for row: DOMTreeRowRenderPlan?,
        in surfaceFrame: CGRect,
        matching nodeID: DOMNode.ID?
    ) -> [CGRect] {
        guard let row,
              !row.isClosingTag,
              row.nodeID == nodeID else {
            return []
        }
        return [CGRect(origin: .zero, size: surfaceFrame.size)]
    }

    private func localMultiSelectedRowBackgroundRects(
        for row: DOMTreeRowRenderPlan?,
        in surfaceFrame: CGRect
    ) -> [CGRect] {
        guard let row,
              !row.isClosingTag,
              multiSelection.contains(row.nodeID) else {
            return []
        }
        return [CGRect(origin: .zero, size: surfaceFrame.size)]
    }

    private func setNeedsDisplayForTextRanges(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else {
            return
        }

        #if DEBUG
        performanceCounters.rowSpanDisplayInvalidationCallCount += 1
        #endif

        var invalidatedRect = CGRect.null
        for range in ranges {
            for row in rowsIntersectingTextRange(range) {
                for rect in contentRowRects(for: row) {
                    invalidatedRect = invalidatedRect.union(rect)
                }
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
        guard isRenderingActive,
              let selectedNodeID = selectionRevealState.pendingSelectedNodeID,
              !rowRenderBuildCoordinator.hasCurrentBuild,
              let row = rowIndex.row(for: selectedNodeID),
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
            animated: isRenderingActive
        )
        selectionRevealState.consumePendingSelection()
    }
}

extension DOMTreeTextView {
    var hasText: Bool {
        !documentText.isEmpty
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
        DOMTreeTextPosition(offset: documentTextUTF16Length)
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
        return (documentText as NSString).substring(with: range)
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
            range = NSRange(location: offset, length: offset < documentTextUTF16Length ? 1 : 0)
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
                NSRange(location: offset, length: offset < documentTextUTF16Length ? 1 : 0)
            )
        )
    }

    private var documentTextUTF16Length: Int {
        (documentText as NSString).length
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
        min(max(0, offset), documentTextUTF16Length)
    }

    private func textOffset(at point: CGPoint) -> Int {
        let contentPoint = convert(point, to: textContentView)
        guard let row = row(at: contentPoint) else {
            if contentPoint.y < 0 {
                return 0
            }
            return documentTextUTF16Length
        }
        let column = min(
            max(0, Int(round(contentPoint.x / Self.characterWidth))),
            row.documentRange.length
        )
        return clampedTextOffset(row.documentRange.location + column)
    }

    private func row(containingTextOffset offset: Int) -> DOMTreeRowRenderPlan? {
        let offset = clampedTextOffset(offset)
        return rows.first { row in
            offset >= row.documentRange.location && offset <= NSMaxRange(row.documentRange)
        }
    }
}

#if DEBUG
extension DOMTreeTextView {
    struct RowSnapshot {
        let text: String
        let depth: Int
        let rowIndex: Int
        let documentRange: NSRange
        let markupRange: NSRange
        let markupStartX: CGFloat
        let hasDisclosure: Bool
        let isOpen: Bool
        let isClosingTag: Bool
        let tokenKinds: [String]
        let tokenTexts: [String]
    }

    struct RowFragmentSnapshot {
        let text: String
        let rowIndex: Int
        let frame: CGRect
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

    var documentTextForTesting: String {
        documentText
    }

    var rowDocumentBaseForegroundColorForTesting: UIColor? {
        baseTextAttributes()[.foregroundColor] as? UIColor
    }

    func rowDocumentForegroundColorForTesting(containing text: String) -> UIColor? {
        textDocument.foregroundColor(containing: text)
    }

    func tokenForegroundColorForTesting(kind: String) -> UIColor? {
        guard let tokenKind = DOMTreeTextView.Token.Kind(rawValue: kind) else {
            return nil
        }
        return resolvedTextAttributes().tokenColors[tokenKind]
    }

    func routeCurrentSelectionInvalidationForTesting() {
        routeSelectionInvalidation(selectionRevision: selectionRevision)
    }

    func waitForPageHighlightTaskForTesting() async {
        await pageHighlightTask?.value
    }

    var rowCountForTesting: Int {
        rows.count
    }

    var rowSnapshotsForTesting: [RowSnapshot] {
        rows.map { rowSnapshot(for: $0) }
    }

    var rowFragmentSnapshotsForTesting: [RowFragmentSnapshot] {
        layoutManager.ensureLayout(for: visibleTextRect(horizontalPadding: 0))
        var snapshots: [RowFragmentSnapshot] = []
        layoutManager.enumerateTextLayoutFragments(
            from: textContentStorage.documentRange.location,
            options: []
        ) { [textDocument] fragment in
            guard let row = textDocument.row(for: fragment) else {
                return true
            }
            snapshots.append(RowFragmentSnapshot(
                text: row.text,
                rowIndex: row.rowIndex,
                frame: fragment.layoutFragmentFrame
            ))
            return true
        }
        return snapshots
    }

    var multiSelectedRowSnapshotsInDisplayOrderForTesting: [RowSnapshot] {
        multiSelection.selectedRowsInDisplayOrder(rowIndex: rowIndex).map { rowSnapshot(for: $0) }
    }

    func removeRowIndexForTesting(containing text: String) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        textDocument.removeRowIndexForTesting(nodeID: row.nodeID)
    }

    func localMarkupTextByNodeIDForTesting(_ nodeIDs: [DOMNode.ID]) -> [DOMNode.ID: String] {
        localMarkupTextByNodeID(for: nodeIDs)
    }

    func deleteRowFromMenuForTesting(containing text: String, undoManager: UndoManager?) async {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        menuModel.configure(
            nodeIDs: [row.nodeID],
            selectedText: nil,
            undoManager: undoManager,
            localMarkupTextByNodeID: localMarkupTextByNodeID(for: [row.nodeID]),
            clearLocalSelection: {}
        )
        if let task = menuModel.deleteSelection() {
            await task.value
        }
    }

    func deleteMultiSelectionFromMenuForTesting(undoManager: UndoManager?) async {
        let nodeIDs = multiSelectedNodeIDsInDisplayOrder()
        guard !nodeIDs.isEmpty else {
            return
        }
        menuModel.configure(
            nodeIDs: nodeIDs,
            selectedText: nil,
            undoManager: undoManager,
            localMarkupTextByNodeID: localMarkupTextByNodeID(for: nodeIDs),
            clearLocalSelection: {}
        )
        if let task = menuModel.deleteSelection() {
            await task.value
        }
    }

    private func rowSnapshot(for row: DOMTreeRowRenderPlan) -> RowSnapshot {
        let line = row.text as NSString
        return RowSnapshot(
            text: row.text,
            depth: row.depth,
            rowIndex: row.rowIndex,
            documentRange: row.documentRange,
            markupRange: row.markupRange,
            markupStartX: markupStartRect(for: row)?.minX ?? 0,
            hasDisclosure: row.hasDisclosure,
            isOpen: row.isOpen,
            isClosingTag: row.isClosingTag,
            tokenKinds: row.tokens.map(\.kind.rawValue),
            tokenTexts: row.tokens.map { line.substring(with: $0.range) }
        )
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
            let hasAttachment = textDocument.hasAttachment(at: attachmentRange.location)
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

    var buildRowRenderPlanCallCountForTesting: Int {
        performanceCounters.buildRowRenderPlanCallCount
    }

    var replaceRowDocumentCallCountForTesting: Int {
        performanceCounters.replaceRowDocumentCallCount
    }

    var incrementalRowDocumentEditCallCountForTesting: Int {
        performanceCounters.incrementalRowDocumentEditCallCount
    }

    var resetTextFragmentViewsCallCountForTesting: Int {
        performanceCounters.resetTextFragmentViewsCallCount
    }

    var rowSpanDisplayInvalidationCallCountForTesting: Int {
        performanceCounters.rowSpanDisplayInvalidationCallCount
    }

    var textSegmentRectsCallCountForTesting: Int {
        performanceCounters.textSegmentRectsCallCount
    }

    var cachedMarkupKeysForTesting: Set<DOMTreeTextView.MarkupCacheKey> {
        rowRenderBuildCoordinator.cachedMarkupKeysForTesting()
    }

    var rowDocumentAppliedTreeRevisionForTesting: UInt64 {
        rowDocumentAppliedTreeRevisionForTestingStorage
    }

    func waitForObservedTreeRevisionForTesting(
        _ minimumRevision: UInt64,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let start = ContinuousClock.now
        while currentTreeSnapshot.revision < minimumRevision {
            if ContinuousClock.now - start >= timeout {
                return false
            }
            await Task.yield()
        }
        return true
    }

    func waitForPendingDOMInvalidationForTesting(
        _ minimumRevision: UInt64,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let start = ContinuousClock.now
        while pendingDOMTreeRenderInvalidation?.revision ?? 0 < minimumRevision {
            if ContinuousClock.now - start >= timeout {
                return false
            }
            await Task.yield()
        }
        return true
    }

    func resetPerformanceCountersForTesting() {
        performanceCounters.reset()
    }

    func waitForRowDocumentAppliedTreeRevisionForTesting(
        _ minimumRevision: UInt64,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        if rowDocumentAppliedTreeRevisionForTestingStorage >= minimumRevision {
            return true
        }

        return await withCheckedContinuation { continuation in
            let waiterID = nextRowDocumentAppliedTreeRevisionWaiterIDForTesting
            nextRowDocumentAppliedTreeRevisionWaiterIDForTesting &+= 1
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveRowDocumentAppliedTreeRevisionWaiterForTesting(
                    id: waiterID,
                    result: false
                )
            }
            rowDocumentAppliedTreeRevisionWaitersForTesting[waiterID] = RowDocumentAppliedTreeRevisionWaiter(
                minimumRevision: minimumRevision,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
        }
    }

    private func recordRowDocumentAppliedTreeRevisionForTesting(_ revision: UInt64) {
        rowDocumentAppliedTreeRevisionForTestingStorage = revision
        let completedWaiterIDs = rowDocumentAppliedTreeRevisionWaitersForTesting.compactMap { id, waiter in
            waiter.minimumRevision <= revision ? id : nil
        }
        for waiterID in completedWaiterIDs {
            resolveRowDocumentAppliedTreeRevisionWaiterForTesting(id: waiterID, result: true)
        }
    }

    private func resolveRowDocumentAppliedTreeRevisionWaiterForTesting(
        id: UInt64,
        result: Bool
    ) {
        guard let waiter = rowDocumentAppliedTreeRevisionWaitersForTesting.removeValue(forKey: id) else {
            return
        }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    private func cancelRowDocumentAppliedTreeRevisionWaitersForTesting() {
        let waiterIDs = Array(rowDocumentAppliedTreeRevisionWaitersForTesting.keys)
        for waiterID in waiterIDs {
            resolveRowDocumentAppliedTreeRevisionWaiterForTesting(id: waiterID, result: false)
        }
    }

    var findFoundRangesForTesting: [NSRange] {
        findDecorationState.foundRanges
    }

    var findHighlightedRangesForTesting: [NSRange] {
        findDecorationState.highlightedRanges
    }

    @discardableResult
    func selectRowForTesting(containing text: String) -> Bool {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return false
        }
        return select(row.nodeID)
    }

    func toggleRowForTesting(containing text: String) {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return
        }
        toggle(row: row)
    }

    @discardableResult
    func primaryClickRowForTesting(containing text: String, modifiers: UIKeyModifierFlags = []) -> Bool {
        guard let row = rows.first(where: { $0.text.contains(text) }) else {
            return false
        }
        dismissDOMMenuAnchor()
        clearTextSelection()
        if modifiers.contains(.shift) {
            extendMultiSelection(to: row)
            return true
        } else if modifiers.contains(.command) || modifiers.contains(.control) {
            toggleMultiSelection(row: row)
            return true
        } else {
            if select(row.nodeID) {
                clearMultiSelection(keepingLast: row.nodeID)
                return true
            }
            return false
        }
    }

    func primaryClickContentPointForTesting(_ point: CGPoint, modifiers: UIKeyModifierFlags = []) {
        handlePrimaryClick(at: point, modifiers: modifiers)
    }

    func disclosureHitPointForTesting(containing text: String) -> CGPoint? {
        guard let row = rows.first(where: { $0.text.contains(text) }),
              let modelHitRect = disclosureHitRect(for: row) else {
            return nil
        }
        layoutManager.ensureLayout(for: visibleTextRect(horizontalPadding: 0))
        var hitPoint: CGPoint?
        layoutManager.enumerateTextLayoutFragments(
            from: textContentStorage.documentRange.location,
            options: []
        ) { [textDocument] fragment in
            guard textDocument.row(for: fragment)?.identity == row.identity else {
                return true
            }
            hitPoint = CGPoint(x: modelHitRect.midX, y: fragment.layoutFragmentFrame.midY)
            return false
        }
        return hitPoint
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
        for range in DOMTreeTextView.FindCoordinator.searchRanges(in: documentText, queryString: query) {
            decorateFindTextRange(range, style: .found)
        }
        if let firstRange = DOMTreeTextView.FindCoordinator.searchRanges(in: documentText, queryString: query).first {
            decorateFindTextRange(firstRange, style: .highlighted)
        }
    }

    func decorateStaleFindTextForTesting(query: String) {
        findCoordinator.decorateStaleFoundTextForTesting(queryString: query)
    }

    func synchronizeDocumentForTesting() async {
        reloadTree(resetFragments: true)
        await waitForRowDocumentForTesting()
    }

    @discardableResult
    func waitForRowDocumentForTesting(timeout: Duration = .seconds(5)) async -> Bool {
        let start = ContinuousClock.now
        while true {
            let elapsed = ContinuousClock.now - start
            guard elapsed < timeout else {
                return false
            }
            if domTreeRenderInvalidationTask != nil {
                flushPendingDOMInvalidationIfNeeded()
                await Task.yield()
                continue
            }
            guard await rowRenderBuildCoordinator.waitForCurrentBuild(timeout: timeout - elapsed) else {
                return false
            }
            if domTreeRenderInvalidationTask == nil,
               !rowRenderBuildCoordinator.hasCurrentBuild {
                return true
            }
        }
    }

    func suspendNextRowRenderBuildForTesting() {
        rowRenderBuildCoordinator.suspendNextBuildForTesting()
    }

    func setUsesInlineRowRenderBuildsForTesting(_ usesInlineBuilds: Bool) {
        rowRenderBuildCoordinator.setUsesInlineBuildsForTesting(usesInlineBuilds)
    }

    func waitForRowRenderBuildSuspensionForTesting() async {
        await rowRenderBuildCoordinator.waitForBuildSuspensionForTesting()
    }

    func resumeRowRenderBuildForTesting() {
        rowRenderBuildCoordinator.resumeSuspendedBuildForTesting()
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
        return textSegmentRects(for: row.documentRange, type: .highlight)
    }

    func hitTestedLineTextForTesting(atContentPoint point: CGPoint) -> String? {
        row(at: point)?.text
    }

    func disclosureHitTestedLineTextForTesting(atContentPoint point: CGPoint) -> String? {
        guard let row = row(at: point),
              isDisclosureHit(at: point, in: row) else {
            return nil
        }
        return row.text
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
#endif // DEBUG

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

#endif // canImport(UIKit)
