#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class DOMTreeViewController: UIViewController {
    private let treeView: DOMTreeTextView
    private weak var inspection: AttachedInspection?
    private var domRootObservation: PortableObservationTracking.Token?
    private var isEnsuringDOMDocumentLoaded = false

    package var domTreeUndoManager: UndoManager? {
        treeView.undoManager
    }

    package init(inspection: AttachedInspection) {
        self.inspection = inspection
        self.treeView = DOMTreeTextView(
            dom: inspection.dom,
            requestChildrenAction: { [weak inspection] nodeID in
                await inspection?.dom.requestChildNodes(for: nodeID) ?? false
            },
            highlightNodeAction: { [weak inspection] nodeID, owner in
                await inspection?.dom.highlightNode(for: nodeID, owner: owner)
            },
            restoreHighlightAction: { [weak inspection] in
                await inspection?.dom.restoreSelectedNodeHighlightOrHide()
            },
            copyNodeTextAction: { [weak inspection] nodeID, kind in
                guard let inspection else {
                    return nil
                }
                return try? await inspection.dom.copyNodeText(kind, for: nodeID)
            },
            deleteNodesAction: { [weak inspection] nodeIDs, undoManager in
                guard let inspection else {
                    return false
                }
                do {
                    try await inspection.dom.deleteNodes(nodeIDs, undoManager: undoManager)
                    return true
                } catch {
                    return false
                }
            }
        )
        super.init(nibName: nil, bundle: nil)
    }

    package init(dom: DOMSession) {
        self.inspection = nil
        self.treeView = DOMTreeTextView(dom: dom)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        domRootObservation?.cancel()
    }

    override package func loadView() {
        treeView.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        treeView.accessibilityIdentifier = "WebInspector.DOM.Tree.NativeTextView"
        view = treeView
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        if let inspection {
            startObservingDOMRoot(inspection: inspection)
        }
    }

    private func applyBackgroundFromTraits() {
        treeView.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    override package func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        ensureDOMDocumentLoadedIfNeeded()
    }

    private func startObservingDOMRoot(inspection: AttachedInspection) {
        domRootObservation?.cancel()
        domRootObservation = withPortableContinuousObservation { [weak self, weak inspection] _ in
            guard let self, let dom = inspection?.dom else {
                return
            }
            _ = dom.treeRevision
            let hasRoot = dom.currentPageRootNode != nil
            let canReloadDocument = dom.canReloadDocument
            ensureDOMDocumentLoadedIfNeeded(
                hasRoot: hasRoot,
                canReloadDocument: canReloadDocument
            )
        }
    }

    private func ensureDOMDocumentLoadedIfNeeded() {
        guard let dom = inspection?.dom else {
            return
        }
        ensureDOMDocumentLoadedIfNeeded(
            hasRoot: dom.currentPageRootNode != nil,
            canReloadDocument: dom.canReloadDocument
        )
    }

    private func ensureDOMDocumentLoadedIfNeeded(
        hasRoot: Bool,
        canReloadDocument: Bool
    ) {
        guard let inspection else {
            return
        }
        guard viewIfLoaded?.window != nil,
              !isEnsuringDOMDocumentLoaded,
              !hasRoot,
              canReloadDocument else {
            return
        }

        isEnsuringDOMDocumentLoaded = true
        Task { @MainActor [weak self, weak inspection] in
            defer {
                self?.isEnsuringDOMDocumentLoaded = false
            }
            _ = await inspection?.dom.ensureDocumentLoaded()
        }
    }
}

#if DEBUG
extension DOMTreeViewController {
    var domRootObservationDeliveryForTesting: PortableObservationTracking.Token? {
        domRootObservation
    }

    var displayedDOMTreeTextViewForTesting: DOMTreeTextView {
        treeView
    }
}
#endif

#Preview("DOM Tree") {
    DOMTreeViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMTreeViewControllerPreview {
    static func makeViewController() -> UINavigationController {
        let viewController = DOMTreeViewController(dom: DOMPreviewFixtures.makeDOMSession())
        return UINavigationController(rootViewController: viewController)
    }
}
#endif
