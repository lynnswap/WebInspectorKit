#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore
import WebInspectorRuntime

@MainActor
package final class DOMTreeViewController: UIViewController {
    private let treeView: DOMTreeTextView
    private weak var session: InspectorSession?
    private let observationScope = ObservationScope()
    private var isEnsuringDOMDocumentLoaded = false

    package init(session: InspectorSession) {
        self.session = session
        self.treeView = DOMTreeTextView(
            dom: session.dom,
            requestChildrenAction: { [weak session] nodeID in
                await session?.requestChildNodes(for: nodeID) ?? false
            },
            highlightNodeAction: { [weak session] nodeID in
                await session?.highlightNode(for: nodeID)
            },
            hideHighlightAction: { [weak session] in
                await session?.hideNodeHighlight()
            },
            copyNodeTextAction: { [weak session] nodeID, kind in
                guard let session else {
                    return nil
                }
                return try? await session.copyDOMNodeText(kind, for: nodeID)
            },
            deleteNodesAction: { [weak session] nodeIDs, undoManager in
                try? await session?.deleteDOMNodes(nodeIDs, undoManager: undoManager)
            }
        )
        super.init(nibName: nil, bundle: nil)
        startObservingDOMRoot(session: session)
    }

    package init(dom: DOMSession) {
        self.session = nil
        self.treeView = DOMTreeTextView(dom: dom)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func loadView() {
        treeView.backgroundColor = .clear
        treeView.accessibilityIdentifier = "WebInspector.DOM.Tree.NativeTextView"
        view = treeView
    }

    override package func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureDOMDocumentLoadedIfNeeded()
    }

    private func startObservingDOMRoot(session: InspectorSession) {
        session.dom.observe(\.treeRevision) { [weak self] _ in
            self?.ensureDOMDocumentLoadedIfNeeded()
        }
        .store(in: observationScope)
    }

    private func ensureDOMDocumentLoadedIfNeeded() {
        guard let session,
              viewIfLoaded?.window != nil,
              !isEnsuringDOMDocumentLoaded,
              session.dom.currentPageRootNode == nil else {
            return
        }

        isEnsuringDOMDocumentLoaded = true
        Task { @MainActor [weak self, weak session] in
            defer {
                self?.isEnsuringDOMDocumentLoaded = false
            }
            _ = await session?.ensureDOMDocumentLoaded()
        }
    }
}

#if DEBUG
extension DOMTreeViewController {
    var displayedDOMTreeTextViewForTesting: DOMTreeTextView {
        treeView
    }
}

#Preview("DOM Tree") {
    let viewController = DOMTreeViewController(dom: DOMPreviewFixtures.makeDOMSession())
    return UINavigationController(rootViewController: viewController)
}
#endif
#endif
