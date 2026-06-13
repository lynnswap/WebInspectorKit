#if canImport(UIKit)
import UIKit

final class DOMTreeTextContentView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DOMTreeTextLayoutFragmentView: UIView {
    let layoutFragment: NSTextLayoutFragment
    var layoutFragmentDrawPoint = CGPoint.zero
    var hoverRowRects: [CGRect] = []
    var hoverRowColor: CGColor?
    var selectedRowRects: [CGRect] = []
    var multiSelectedRowRects: [CGRect] = []
    var selectedRowColor: CGColor?
    var findHighlightRects: [CGRect] = []
    var findHighlightColor: CGColor?
    var currentFindHighlightRects: [CGRect] = []
    var currentFindHighlightColor: CGColor?

    init(layoutFragment: NSTextLayoutFragment, frame: CGRect) {
        self.layoutFragment = layoutFragment
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }

        if let hoverRowColor, !hoverRowRects.isEmpty {
            context.saveGState()
            context.setFillColor(hoverRowColor)
            for rowRect in hoverRowRects where rowRect.intersects(rect) {
                context.fill(rowRect)
            }
            context.restoreGState()
        }

        if let selectedRowColor, !selectedRowRects.isEmpty || !multiSelectedRowRects.isEmpty {
            context.saveGState()
            context.setFillColor(selectedRowColor)
            for rowRect in multiSelectedRowRects where rowRect.intersects(rect) {
                context.fill(rowRect)
            }
            for rowRect in selectedRowRects where rowRect.intersects(rect) {
                context.fill(rowRect)
            }
            context.restoreGState()
        }

        if let findHighlightColor, !findHighlightRects.isEmpty {
            context.saveGState()
            context.setFillColor(findHighlightColor)
            for findRect in findHighlightRects where findRect.intersects(rect) {
                context.fill(findRect)
            }
            context.restoreGState()
        }

        if let currentFindHighlightColor, !currentFindHighlightRects.isEmpty {
            context.saveGState()
            context.setFillColor(currentFindHighlightColor)
            for findRect in currentFindHighlightRects where findRect.intersects(rect) {
                context.fill(findRect)
            }
            context.restoreGState()
        }

        layoutFragment.draw(at: layoutFragmentDrawPoint, in: context)
    }
}
#endif
