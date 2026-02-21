import Observation
import WebInspectorKitCore

@MainActor
@Observable
public final class WISessionStore {
    public private(set) var viewState = WISessionViewState()

    @ObservationIgnored private var eventTask: Task<Void, Never>?

    public init() {}

    deinit {
        eventTask?.cancel()
    }

    public func bind(to events: AsyncStream<WISessionEvent>) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                apply(event)
            }
        }
    }

    public var dom: WIDOMViewState {
        viewState.dom
    }

    public var network: WINetworkViewState {
        viewState.network
    }

    public var selectedPaneID: String? {
        viewState.selectedPaneID
    }

    public var lifecycle: WISessionLifecycle {
        viewState.lifecycle
    }

    public var isSuspended: Bool {
        viewState.lifecycle == .suspended
    }

    public var isDisconnected: Bool {
        viewState.lifecycle == .disconnected
    }

    private func apply(_ event: WISessionEvent) {
        switch event {
        case let .stateChanged(state):
            viewState = state
        case let .recoverableError(message):
            viewState.lastRecoverableError = message
        }
    }
}
