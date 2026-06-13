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
    private var scrollEdgeObservation: PortableObservationTracking.Token?
    private var interaction: UIInteraction?
    private weak var registeredInteractionScrollView: UIScrollView?
#if DEBUG
    private var observationDelivery: PortableObservationTracking.Token?
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
        scrollEdgeObservation?.cancel()
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
            let token = withPortableContinuousObservation { [weak self] _ in
                guard let self else { return }
                render(scrollEdgeState)
            }
            scrollEdgeObservation = token
#if DEBUG
            observationDelivery = token
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

    var observationDeliveryForTesting: PortableObservationTracking.Token? {
        observationDelivery
    }
}
#endif
#endif
