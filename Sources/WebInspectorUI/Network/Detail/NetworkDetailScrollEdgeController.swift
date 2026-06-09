#if canImport(UIKit)
import Observation
import ObservationBridge
import UIKit

@MainActor
@Observable
final class NetworkDetailScrollEdgeState {
    var isPreviewRoleControlVisible = false
    var contentScrollView: UIScrollView?
}

@MainActor
final class NetworkDetailScrollEdgeController {
    let scrollEdgeState = NetworkDetailScrollEdgeState()
    private let observationScope = ObservationScope()
    private var interaction: UIInteraction?
    private weak var registeredInteractionScrollView: UIScrollView?
#if DEBUG
    private var observationDelivery: ObservationDelivery?
#endif

    var isPreviewRoleControlVisible: Bool {
        get {
            scrollEdgeState.isPreviewRoleControlVisible
        }
        set {
            scrollEdgeState.isPreviewRoleControlVisible = newValue
        }
    }

    var contentScrollView: UIScrollView? {
        get {
            scrollEdgeState.contentScrollView
        }
        set {
            scrollEdgeState.contentScrollView = newValue
        }
    }

    isolated deinit {
        observationScope.cancelAll()
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
            let delivery = observationScope.observe(scrollEdgeState) { [weak self] _, state in
                self?.render(state)
            }
            render(scrollEdgeState)
#if DEBUG
            observationDelivery = delivery
#endif
        }
    }

    private func render(_ state: NetworkDetailScrollEdgeState) {
        if #available(iOS 26.0, *) {
            let contentScrollView = state.contentScrollView
            guard let interaction = interaction as? UIScrollEdgeElementContainerInteraction else {
                return
            }
            let interactionScrollView = state.isPreviewRoleControlVisible ? contentScrollView : nil
            guard registeredInteractionScrollView !== interactionScrollView else {
                return
            }
            interaction.scrollView = interactionScrollView
            registeredInteractionScrollView = interactionScrollView
        }
    }
}

#if DEBUG
extension NetworkDetailScrollEdgeController {
    @available(iOS 26.0, *)
    var interactionForTesting: UIScrollEdgeElementContainerInteraction? {
        interaction as? UIScrollEdgeElementContainerInteraction
    }

    var observationDeliveryForTesting: ObservationDelivery? {
        observationDelivery
    }
}
#endif
#endif
