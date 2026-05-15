#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore

@MainActor
package final class DOMElementViewController: UIViewController {
    private let dom: DOMSession
    private let observationScope = ObservationScope()

    package init(dom: DOMSession) {
        self.dom = dom
        super.init(nibName: nil, bundle: nil)
        startObservingDOM()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        render()
    }

    private func startObservingDOM() {
        dom.observe([\.treeRevision, \.selectionRevision]) { [weak self] in
            self?.render()
        }
        .store(in: observationScope)
    }

    private func render() {
        guard isViewLoaded else {
            return
        }

        if dom.currentPageRootNode == nil {
            applyUnavailableState(
                text: webInspectorLocalized("dom.element.loading", default: "Loading DOM..."),
                secondaryText: nil,
                image: UIImage(systemName: "arrow.clockwise")
            )
            return
        }

        guard let selectedNode = dom.selectedNode else {
            applyUnavailableState(
                text: webInspectorLocalized("dom.element.select_prompt", default: "Select an element"),
                secondaryText: webInspectorLocalized("dom.element.hint", default: "Choose a node in the DOM tree to inspect it."),
                image: UIImage(systemName: "cursorarrow.rays")
            )
            return
        }

        applyUnavailableState(
            text: webInspectorLocalized("dom.element.placeholder.title", default: "Element details"),
            secondaryText: displayName(for: selectedNode),
            image: UIImage(systemName: "info.circle")
        )
    }

    private func applyUnavailableState(text: String, secondaryText: String?, image: UIImage?) {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = text
        configuration.secondaryText = secondaryText
        configuration.image = image
        contentUnavailableConfiguration = configuration
    }

    private func displayName(for node: DOMNode) -> String {
        switch node.nodeType {
        case .element:
            let name = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
            return "<\(name)>"
        case .text:
            return "#text"
        case .comment:
            return "<!-- \(node.nodeValue) -->"
        case .documentType:
            return "<!DOCTYPE \(node.nodeName)>"
        case .document:
            return "#document"
        case .documentFragment:
            return "#document-fragment"
        default:
            return node.nodeName
        }
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("DOM Element") {
    let dom = DOMPreviewFixtures.makeDOMSession()
    if let root = dom.currentPageRootNode,
       let body = dom.visibleDOMTreeChildren(of: root).last,
       let selectedNode = dom.visibleDOMTreeChildren(of: body).first {
        dom.selectNode(selectedNode.id)
    }
    return UINavigationController(rootViewController: DOMElementViewController(dom: dom))
}
#endif
#endif
