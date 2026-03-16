
import Foundation

public enum DOMSelectionCopyKind: String, CaseIterable, Sendable {
    case html = "HTML"
    case selectorPath = "selector"
    case xpath = "XPath"

    var logLabel: String { rawValue }

    var jsFunction: String {
        switch self {
        case .html:
            return "outerHTMLForNode"
        case .selectorPath:
            return "selectorPathForNode"
        case .xpath:
            return "xpathForNode"
        }
    }
}
