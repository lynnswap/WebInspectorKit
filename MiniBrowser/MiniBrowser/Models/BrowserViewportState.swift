#if canImport(UIKit)
import UIKit

enum BrowserBottomChromeMode: Equatable {
    case normal
    case hiddenForKeyboard
}

struct BrowserViewportState: Equatable {
    let safeAreaInsets: UIEdgeInsets
    let topObscuredHeight: CGFloat
    let bottomObscuredHeight: CGFloat
    let keyboardOverlapHeight: CGFloat
    let inputAccessoryOverlapHeight: CGFloat
    let bottomChromeMode: BrowserBottomChromeMode

    var finalObscuredInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: max(0, topObscuredHeight),
            left: 0,
            bottom: resolvedBottomObscuredHeight,
            right: 0
        )
    }

    var safeAreaAffectedEdges: UIRectEdge {
        [.top, .bottom]
    }

    private var resolvedBottomObscuredHeight: CGFloat {
        let overlayHeight = bottomChromeMode == .normal ? bottomObscuredHeight : 0
        return max(0, overlayHeight, keyboardOverlapHeight, inputAccessoryOverlapHeight)
    }
}
#endif
