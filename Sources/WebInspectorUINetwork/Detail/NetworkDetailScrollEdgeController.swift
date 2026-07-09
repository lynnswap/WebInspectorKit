#if canImport(UIKit)
import WebInspectorUIBase
import UIKit

@MainActor
package protocol NetworkBodyScrollEdgeSink: AnyObject {
    var contentScrollView: UIScrollView? { get set }
}

@MainActor
final class NetworkDetailScrollEdgeController: NetworkBodyScrollEdgeSink {
    private var interaction: UIInteraction?
    private weak var registeredInteractionScrollView: UIScrollView?
    private var previewRoleControlIsVisible = false
    private weak var visibleContentScrollView: UIScrollView?

    var isPreviewRoleControlVisible: Bool {
        get {
            previewRoleControlIsVisible
        }
        set {
            guard previewRoleControlIsVisible != newValue else {
                return
            }
            previewRoleControlIsVisible = newValue
            apply()
        }
    }

    var contentScrollView: UIScrollView? {
        get {
            visibleContentScrollView
        }
        set {
            guard visibleContentScrollView !== newValue else {
                return
            }
            visibleContentScrollView = newValue
            apply()
        }
    }

    func install(previewRoleControlContainerView: UIView) {
        guard interaction == nil else {
            return
        }
        if #available(iOS 26.0, *) {
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.edge = .top
            previewRoleControlContainerView.addInteraction(interaction)
            self.interaction = interaction
            apply()
        }
    }

    private func apply() {
        if #available(iOS 26.0, *) {
            guard let interaction = interaction as? UIScrollEdgeElementContainerInteraction else {
                return
            }
            let interactionScrollView = previewRoleControlIsVisible ? visibleContentScrollView : nil
            guard registeredInteractionScrollView !== interactionScrollView else {
                return
            }
            interaction.scrollView = interactionScrollView
            registeredInteractionScrollView = interactionScrollView
        }
    }
}

#endif
