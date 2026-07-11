#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import WebInspectorProxyKit
import UIKit

#Preview("DOM Element") {
    DOMElementViewControllerPreview.makeViewController()
}

/// Static DataKit preview: styles are seeded through the production load
/// path (`seedSelectedNodeStyles`). There is no backend, so property
/// toggles are refused and roll back (the legacy preview emulated a live
/// `CSS.setStyleText` round-trip through a fake transport).
@MainActor
private enum DOMElementViewControllerPreview {
    static func makeViewController() -> UINavigationController {
        let context = DOMPreviewFixtures.makeWebInspectorModelContext()
        if let body = DOMPreviewFixtures.firstElement(named: "body", in: context) {
            try! context.selectDOMNode(body)
            context.seedSelectedNodeStyles(matchedStyles: previewMatchedStyles())
        }
        return UINavigationController(rootViewController: DOMElementViewController(context: context))
    }

    private static func previewMatchedStyles() -> CSS.MatchedStyles {
        let cssText = "margin: 0;\n/* box-sizing: border-box; */\nfont-size: 12px;"
        let styleID = CSS.Style.ID("preview-style")
        let style = CSS.Style(
            id: styleID,
            properties: [
                CSS.Property(
                    id: CSS.Property.ID("preview-style:0"),
                    name: "margin",
                    value: "0",
                    text: "margin: 0;",
                    status: .active,
                    isEditable: true
                ),
                CSS.Property(
                    id: CSS.Property.ID("preview-style:1"),
                    name: "box-sizing",
                    value: "border-box",
                    text: "/* box-sizing: border-box; */",
                    status: .disabled,
                    isEditable: true
                ),
                CSS.Property(
                    id: CSS.Property.ID("preview-style:2"),
                    name: "font-size",
                    value: "12px",
                    text: "font-size: 12px;",
                    status: .inactive,
                    isEditable: true
                ),
            ],
            cssText: cssText,
            isEditable: true
        )
        let rule = CSS.Rule(
            id: CSS.Rule.ID("preview-rule"),
            selectorList: CSS.Rule.SelectorList(selectors: ["body"], text: "body"),
            sourceURL: "preview.css",
            sourceLine: 1,
            origin: CSS.Origin(rawValue: "author"),
            style: style
        )
        return CSS.MatchedStyles(matchedRules: [rule])
    }
}
#endif
