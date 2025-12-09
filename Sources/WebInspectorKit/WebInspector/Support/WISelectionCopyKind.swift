
import Foundation

public enum WISelectionCopyKind: String,CaseIterable {
    case html = "HTML"
    case selectorPath = "selector"
    case xpath = "XPath"

    var logLabel: String { rawValue }
    
    var jsFunction:String{
        switch self {
        case .html:"outerHTMLForNode"
        case .selectorPath:"selectorPathForNode"
        case .xpath:"xpathForNode"
        }
    }
}
