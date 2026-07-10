#if canImport(UIKit)
import Observation
import UIKit
import WebInspectorDataKit
import WebInspectorUINetwork

/// Owns view controllers and asynchronous resources whose lifetime is bounded
/// by one root inspector presentation.
@MainActor
@Observable
package final class PresentationContentStore {
    package enum NetworkResourceStatus: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private enum NetworkResourceState {
        case idle
        case loading(contextEpoch: Int, generation: UInt64)
        case ready(contextEpoch: Int, generation: UInt64, model: NetworkPanelModel)
        case failed(contextEpoch: Int, generation: UInt64, message: String)
    }

    private final class WeakNetworkResourceViewController {
        weak var value: NetworkTabResourceViewController?

        init(_ value: NetworkTabResourceViewController) {
            self.value = value
        }
    }

    package typealias NetworkPanelModelFactory = @MainActor (
        _ context: WebInspectorModelContext
    ) async throws -> NetworkPanelModel

    @ObservationIgnored private let contentCache = WebInspectorTab.ContentCache()
    @ObservationIgnored private let makeNetworkPanelModel: NetworkPanelModelFactory
    @ObservationIgnored private var networkResourceTask: Task<Void, Never>?
    @ObservationIgnored private var networkRetirementTask: Task<Void, Never>?
    @ObservationIgnored private var networkResourceViewControllers: [WeakNetworkResourceViewController] = []
    @ObservationIgnored private var networkContext: WebInspectorModelContext?
    private var networkResourceState: NetworkResourceState = .idle
    package private(set) var contextEpoch: Int?
    package private(set) var networkResourceGeneration: UInt64 = 0
    package private(set) var networkResourceRevision: UInt64 = 0
    @ObservationIgnored private var networkRetirementGeneration: UInt64 = 0

    package init(
        makeNetworkPanelModel: @escaping NetworkPanelModelFactory = { context in
            try await NetworkPanelModel.make(context: context)
        }
    ) {
        self.makeNetworkPanelModel = makeNetworkPanelModel
    }

    isolated deinit {
        networkResourceTask?.cancel()
        networkRetirementTask?.cancel()
        if case let .ready(_, _, model) = networkResourceState {
            model.synchronouslyCancelForOwnerDeinit()
        }
        for resourceViewController in networkResourceViewControllers {
            resourceViewController.value?.synchronouslyResetForOwnerDeinit()
        }
        contentCache.removeAll()
    }

    package var networkResourceStatus: NetworkResourceStatus {
        switch networkResourceState {
        case .idle:
            .idle
        case .loading:
            .loading
        case .ready:
            .ready
        case let .failed(_, _, message):
            .failed(message)
        }
    }

    package func viewController<Content: UIViewController>(
        for key: WebInspectorTab.ContentKey,
        contextEpoch: Int,
        make: () -> Content
    ) -> Content {
        prepare(for: contextEpoch)
        return contentCache.viewController(for: key, make: make)
    }

    package func networkViewController(
        context: WebInspectorModelContext,
        contextEpoch: Int,
        makeReadyViewController: @escaping @MainActor (NetworkPanelModel) -> UIViewController
    ) -> NetworkTabResourceViewController {
        prepare(for: contextEpoch)
        if let networkContext {
            precondition(
                networkContext === context,
                "A presentation context must change together with its context epoch."
            )
        } else {
            networkContext = context
        }
        // A UITab owns the view controller returned by its provider. Resource
        // state is shared by the root store, but the native wrapper cannot be
        // cached and handed to a later UITab instance.
        let viewController = NetworkTabResourceViewController(
            makeReadyViewController: makeReadyViewController
        )
        networkResourceViewControllers.append(WeakNetworkResourceViewController(viewController))

        switch networkResourceState {
        case .idle:
            startNetworkResource(context: context, contextEpoch: contextEpoch)
        case let .loading(resourceEpoch, _),
             let .ready(resourceEpoch, _, _),
             let .failed(resourceEpoch, _, _):
            precondition(
                resourceEpoch == contextEpoch,
                "A Network resource must change together with its presentation context epoch."
            )
        }
        renderNetworkResource(on: viewController)
        return viewController
    }

    /// Begins a context transition synchronously. Any next Network load waits
    /// for the old load and model retirement before it can publish ready state.
    package func prepare(for contextEpoch: Int) {
        guard self.contextEpoch != contextEpoch else {
            return
        }
        beginNetworkRetirement()
        contentCache.removeAll()
        networkResourceViewControllers.removeAll()
        networkContext = nil
        self.contextEpoch = contextEpoch
    }

    /// Retires every presentation resource and waits for asynchronous owners.
    package func clear() async {
        beginNetworkRetirement()
        contentCache.removeAll()
        networkResourceViewControllers.removeAll()
        networkContext = nil
        contextEpoch = nil
        let retirementGeneration = networkRetirementGeneration
        let retirementTask = networkRetirementTask
        await retirementTask?.value
        if networkRetirementGeneration == retirementGeneration {
            networkRetirementTask = nil
        }
    }

    private func startNetworkResource(
        context: WebInspectorModelContext,
        contextEpoch: Int
    ) {
        precondition(
            self.contextEpoch == contextEpoch,
            "A Network resource cannot start for an inactive presentation context epoch."
        )
        guard case .idle = networkResourceState else {
            return
        }

        let generation = advanceNetworkResourceGeneration()
        networkResourceState = .loading(
            contextEpoch: contextEpoch,
            generation: generation
        )
        advanceNetworkResourceRevision()
        renderNetworkResource()

        let retirementTask = networkRetirementTask
        let makeNetworkPanelModel = makeNetworkPanelModel
        networkResourceTask = Task { @MainActor [weak self] in
            await retirementTask?.value
            guard self?.isCurrentNetworkResource(
                contextEpoch: contextEpoch,
                generation: generation
            ) == true else {
                return
            }
            self?.networkRetirementTask = nil

            do {
                let model = try await makeNetworkPanelModel(context)
                guard let self,
                      isCurrentNetworkResource(
                        contextEpoch: contextEpoch,
                        generation: generation
                      ) else {
                    await model.retire()
                    return
                }
                networkResourceTask = nil
                networkResourceState = .ready(
                    contextEpoch: contextEpoch,
                    generation: generation,
                    model: model
                )
                advanceNetworkResourceRevision()
                renderNetworkResource()
            } catch {
                guard let self,
                      isCurrentNetworkResource(
                        contextEpoch: contextEpoch,
                        generation: generation
                      ) else {
                    return
                }
                let message = error.localizedDescription
                networkResourceTask = nil
                networkResourceState = .failed(
                    contextEpoch: contextEpoch,
                    generation: generation,
                    message: message
                )
                advanceNetworkResourceRevision()
                renderNetworkResource()
            }
        }
    }

    private func beginNetworkRetirement() {
        let loadTask = networkResourceTask
        networkResourceTask = nil
        loadTask?.cancel()
        let readyModel: NetworkPanelModel?
        if case let .ready(_, _, model) = networkResourceState {
            readyModel = model
        } else {
            readyModel = nil
        }
        let previousRetirementTask = networkRetirementTask

        _ = advanceNetworkResourceGeneration()
        networkResourceState = .idle
        advanceNetworkResourceRevision()
        renderNetworkResource()

        guard loadTask != nil || readyModel != nil || previousRetirementTask != nil else {
            networkRetirementTask = nil
            return
        }
        precondition(
            networkRetirementGeneration < UInt64.max,
            "Network resource retirement generation overflowed."
        )
        networkRetirementGeneration += 1
        let retirementGeneration = networkRetirementGeneration
        networkRetirementTask = Task { @MainActor [weak self] in
            await previousRetirementTask?.value
            await loadTask?.value
            await readyModel?.retire()
            guard let self,
                  networkRetirementGeneration == retirementGeneration else {
                return
            }
            networkRetirementTask = nil
        }
    }

    private func isCurrentNetworkResource(
        contextEpoch: Int,
        generation: UInt64
    ) -> Bool {
        guard self.contextEpoch == contextEpoch,
              networkResourceGeneration == generation else {
            return false
        }
        switch networkResourceState {
        case let .loading(resourceEpoch, resourceGeneration):
            return resourceEpoch == contextEpoch && resourceGeneration == generation
        case .idle, .ready, .failed:
            return false
        }
    }

    @discardableResult
    private func advanceNetworkResourceGeneration() -> UInt64 {
        precondition(
            networkResourceGeneration < UInt64.max,
            "Network resource generation overflowed."
        )
        networkResourceGeneration += 1
        return networkResourceGeneration
    }

    private func advanceNetworkResourceRevision() {
        precondition(
            networkResourceRevision < UInt64.max,
            "Network resource revision overflowed."
        )
        networkResourceRevision += 1
    }

    private func renderNetworkResource() {
        networkResourceViewControllers = networkResourceViewControllers.filter { box in
            guard let viewController = box.value else {
                return false
            }
            renderNetworkResource(on: viewController)
            return true
        }
    }

    private func renderNetworkResource(on viewController: NetworkTabResourceViewController) {
        switch networkResourceState {
        case .idle, .loading:
            viewController.showLoading(revision: networkResourceRevision)
        case let .ready(_, _, model):
            viewController.showReady(model, revision: networkResourceRevision)
        case let .failed(_, _, message):
            viewController.showFailure(message, revision: networkResourceRevision)
        }
    }

    #if DEBUG
    package var contentCountForTesting: Int {
        contentCache.countForTesting
    }

    package var contentCacheForTesting: WebInspectorTab.ContentCache {
        contentCache
    }

    package var networkPanelModelForTesting: NetworkPanelModel? {
        guard case let .ready(_, _, model) = networkResourceState else {
            return nil
        }
        return model
    }

    package func waitForNetworkResourceTaskForTesting() async {
        await networkResourceTask?.value
    }

    package func waitForNetworkRetirementForTesting() async {
        await networkRetirementTask?.value
    }
    #endif
}
#endif
