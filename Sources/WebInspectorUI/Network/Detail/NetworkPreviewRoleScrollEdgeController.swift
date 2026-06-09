#if canImport(UIKit)
import Observation
import ObservationBridge
import UIKit

@MainActor
@Observable
final class NetworkPreviewRoleScrollEdgeState {
    var isControlVisible = false
    var scrollView: UIScrollView?
}

@MainActor
final class NetworkPreviewRoleScrollEdgeController {
    let scrollEdgeState = NetworkPreviewRoleScrollEdgeState()
    private let observationScope = ObservationScope()
    private var interaction: UIInteraction?
#if DEBUG
    private var observationDelivery: ObservationDelivery?
#endif

    var isControlVisible: Bool {
        get {
            scrollEdgeState.isControlVisible
        }
        set {
            scrollEdgeState.isControlVisible = newValue
        }
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    func install(in containerView: UIView) {
        guard interaction == nil else {
            return
        }
        if #available(iOS 26.0, *) {
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.edge = .top
            containerView.addInteraction(interaction)
            self.interaction = interaction
            let delivery = observationScope.observe(scrollEdgeState) { [weak self] _, state in
                self?.render(state)
            }
#if DEBUG
            observationDelivery = delivery
#endif
        }
    }

    private func render(_ state: NetworkPreviewRoleScrollEdgeState) {
        if #available(iOS 26.0, *) {
            guard let interaction = interaction as? UIScrollEdgeElementContainerInteraction else {
                return
            }
            interaction.scrollView = state.isControlVisible ? state.scrollView : nil
        }
    }
}

#if DEBUG
extension NetworkPreviewRoleScrollEdgeController {
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
