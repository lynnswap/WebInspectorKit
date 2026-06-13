#if canImport(UIKit)
import UIKit

@MainActor
final class DOMTreeViewportLayoutCoordinator {
    private weak var textContentView: DOMTreeTextContentView?
    private let fragmentViewMap = NSMapTable<NSTextLayoutFragment, DOMTreeTextLayoutFragmentView>.weakToWeakObjects()
    private var lastUsedFragmentViews: Set<DOMTreeTextLayoutFragmentView> = []

    init(textContentView: DOMTreeTextContentView) {
        self.textContentView = textContentView
    }

    func prepareForLayout() {
        guard let textContentView else {
            lastUsedFragmentViews.removeAll(keepingCapacity: true)
            return
        }
        lastUsedFragmentViews = Set(textContentView.subviews.compactMap { $0 as? DOMTreeTextLayoutFragmentView })
    }

    func configureRenderingSurface(
        for textLayoutFragment: NSTextLayoutFragment,
        visibleTextRect: CGRect,
        configureHighlights: (DOMTreeTextLayoutFragmentView, CGRect) -> Void,
        configureRowBackgrounds: (DOMTreeTextLayoutFragmentView, CGRect) -> Void
    ) {
        guard let textContentView else {
            return
        }
        let layoutFrame = textLayoutFragment.layoutFragmentFrame
        let surfaceFrame = CGRect(
            x: visibleTextRect.minX,
            y: layoutFrame.minY,
            width: max(visibleTextRect.width, 1),
            height: layoutFrame.height
        )
        let fragmentView: DOMTreeTextLayoutFragmentView
        if let cachedView = fragmentViewMap.object(forKey: textLayoutFragment) {
            fragmentView = cachedView
            lastUsedFragmentViews.remove(cachedView)
        } else {
            fragmentView = DOMTreeTextLayoutFragmentView(layoutFragment: textLayoutFragment, frame: surfaceFrame)
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }

        fragmentView.layoutFragmentDrawPoint = CGPoint(
            x: layoutFrame.minX - surfaceFrame.minX,
            y: layoutFrame.minY - surfaceFrame.minY
        )
        configureHighlights(fragmentView, surfaceFrame)
        configureRowBackgrounds(fragmentView, surfaceFrame)

        if !fragmentView.frame.wiIsNearlyEqual(to: surfaceFrame) {
            fragmentView.frame = surfaceFrame
            fragmentView.setNeedsDisplay()
        }
        if fragmentView.superview !== textContentView {
            textContentView.addSubview(fragmentView)
        }
    }

    func finishLayout() {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
        }
        lastUsedFragmentViews.removeAll()
    }

    func resetFragmentViews() {
        guard let textContentView else {
            fragmentViewMap.removeAllObjects()
            lastUsedFragmentViews.removeAll(keepingCapacity: true)
            return
        }
        for case let fragmentView as DOMTreeTextLayoutFragmentView in textContentView.subviews {
            fragmentView.removeFromSuperview()
        }
        fragmentViewMap.removeAllObjects()
        lastUsedFragmentViews.removeAll(keepingCapacity: true)
    }
}
#endif
