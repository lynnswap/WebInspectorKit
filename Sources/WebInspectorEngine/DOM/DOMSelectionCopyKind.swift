
import Foundation

package enum DOMSelectionCopyKind: String, CaseIterable, Sendable {
    case html = "HTML"
    case selectorPath = "selector"
    case xpath = "XPath"

    var logLabel: String { rawValue }
}
