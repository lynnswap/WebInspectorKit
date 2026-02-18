#if DEBUG && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import WebInspectorKitCore

@MainActor
private enum ElementDetailsPreviewScenario {
    enum Mode {
        case empty
        case selected
        case selectedEditableAttributes
    }

    static func makeInspector(mode: Mode) -> WIDOMPaneViewModel {
        let inspector = WIDOMPaneViewModel(session: DOMSession())
        switch mode {
        case .empty:
            break
        case .selected:
            inspector.selection.nodeId = 42
            inspector.selection.preview = "<span aria-label=\"スノーボード\">...</span>"
            inspector.selection.selectorPath = "#hplogo > span"
            inspector.selection.attributes = [
                DOMAttribute(nodeId: 42, name: "alt", value: "スノーボード 2026"),
                DOMAttribute(nodeId: 42, name: "id", value: "hplogo"),
                DOMAttribute(nodeId: 42, name: "src", value: "/logos/doodles/2026/snowboarding.gif")
            ]
            inspector.selection.matchedStyles = [
                DOMMatchedStyleRule(
                    origin: .author,
                    selectorText: ".logo span[aria-label]",
                    declarations: [
                        DOMMatchedStyleDeclaration(name: "display", value: "inline-block", important: false),
                        DOMMatchedStyleDeclaration(name: "max-width", value: "100%", important: false)
                    ],
                    sourceLabel: "styles.css:120"
                )
            ]
        case .selectedEditableAttributes:
            inspector.selection.nodeId = 101
            inspector.selection.preview = "<img alt=\"スノーボード 2026\" src=\"/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif\">"
            inspector.selection.selectorPath = "#hplogo > img"
            inspector.selection.attributes = [
                DOMAttribute(
                    nodeId: 101,
                    name: "style",
                    value: """
                    border:none;
                    max-width:100%;
                    margin:8px 0;
                    min-width:1px;
                    min-height:1px
                    """
                ),
                DOMAttribute(nodeId: 101, name: "alt", value: "スノーボード 2026"),
                DOMAttribute(
                    nodeId: 101,
                    name: "src",
                    value: "/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif"
                )
            ]
            inspector.selection.matchedStyles = [
                DOMMatchedStyleRule(
                    origin: .author,
                    selectorText: ".logo img[alt]",
                    declarations: [
                        DOMMatchedStyleDeclaration(name: "display", value: "inline-block", important: false),
                        DOMMatchedStyleDeclaration(name: "max-width", value: "100%", important: false),
                        DOMMatchedStyleDeclaration(name: "height", value: "auto", important: false)
                    ],
                    sourceLabel: "styles.css:188"
                )
            ]
        }
        return inspector
    }
}

@MainActor
private struct ElementDetailsPreviewContainer: UIViewControllerRepresentable {
    let mode: ElementDetailsPreviewScenario.Mode

    func makeUIViewController(context: Context) -> UIViewController {
        let inspector = ElementDetailsPreviewScenario.makeInspector(mode: mode)
        let root = ElementDetailsTabViewController(inspector: inspector)
        return UINavigationController(rootViewController: root)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

#Preview("Element Empty") {
    ElementDetailsPreviewContainer(mode: .empty)
}

#Preview("Element Selected") {
    ElementDetailsPreviewContainer(mode: .selected)
}

#Preview("Element Selected (Editable Attributes)") {
    ElementDetailsPreviewContainer(mode: .selectedEditableAttributes)
}
#endif
