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

    package enum CustomResourceStatus: Equatable, Sendable {
        case loading
        case ready
        case failed(String)
    }

    private enum NetworkResourceState {
        case idle
        case loading(generation: UInt64)
        case ready(generation: UInt64, model: NetworkPanelModel)
        case failed(generation: UInt64, message: String)
    }

    private enum CustomResourceState {
        case loading(generation: UInt64)
        case ready(generation: UInt64, viewController: UIViewController)
        case failed(generation: UInt64, message: String)

        var generation: UInt64 {
            switch self {
            case let .loading(generation),
                 let .ready(generation, _),
                 let .failed(generation, _):
                generation
            }
        }
    }

    private final class WeakNetworkResourceViewController {
        weak var value: NetworkTabResourceViewController?

        init(_ value: NetworkTabResourceViewController) {
            self.value = value
        }
    }

    private final class WeakCustomResourceViewController {
        weak var value: CustomTabResourceViewController?

        init(_ value: CustomTabResourceViewController) {
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
    @ObservationIgnored private var customResourceStates: [
        WebInspectorTab.ContentKey: CustomResourceState
    ] = [:]
    @ObservationIgnored private var customResourceTasks: [
        WebInspectorTab.ContentKey: Task<Void, Never>
    ] = [:]
    @ObservationIgnored private var customResourceViewControllers: [
        WebInspectorTab.ContentKey: [WeakCustomResourceViewController]
    ] = [:]
    @ObservationIgnored private var customResourceGenerations: [
        WebInspectorTab.ContentKey: UInt64
    ] = [:]
    @ObservationIgnored private var customResourceRevisions: [
        WebInspectorTab.ContentKey: UInt64
    ] = [:]
    private var networkResourceState: NetworkResourceState = .idle
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
        for task in customResourceTasks.values {
            task.cancel()
        }
        if case let .ready(_, model) = networkResourceState {
            model.synchronouslyCancelForOwnerDeinit()
        }
        for resourceViewController in networkResourceViewControllers {
            resourceViewController.value?.synchronouslyResetForOwnerDeinit()
        }
        for resourceViewControllers in customResourceViewControllers.values {
            for resourceViewController in resourceViewControllers {
                resourceViewController.value?.synchronouslyResetForOwnerDeinit()
            }
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
        case let .failed(_, message):
            .failed(message)
        }
    }

    package func viewController<Content: UIViewController>(
        for key: WebInspectorTab.ContentKey,
        make: () -> Content
    ) -> Content {
        return contentCache.viewController(for: key, make: make)
    }

    package func networkViewController(
        context: WebInspectorModelContext,
        makeReadyViewController: @escaping @MainActor (NetworkPanelModel) -> UIViewController
    ) -> NetworkTabResourceViewController {
        if let networkContext {
            precondition(
                networkContext === context,
                "One presentation content store cannot bind multiple model contexts."
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
            startNetworkResource(context: context)
        case .loading, .ready, .failed:
            break
        }
        renderNetworkResource(on: viewController)
        return viewController
    }

    package func customViewController(
        for key: WebInspectorTab.ContentKey,
        session: WebInspectorSession,
        makeViewController: @escaping @MainActor (WebInspectorSession) async throws -> UIViewController
    ) -> CustomTabResourceViewController {
        let viewController = CustomTabResourceViewController { [weak self, session] in
            self?.retryCustomResource(
                for: key,
                session: session,
                makeViewController: makeViewController
            )
        }
        customResourceViewControllers[key, default: []].append(
            WeakCustomResourceViewController(viewController)
        )
        if customResourceStates[key] == nil {
            startCustomResource(
                for: key,
                session: session,
                makeViewController: makeViewController
            )
        }
        renderCustomResource(for: key, on: viewController)
        return viewController
    }
    /// Retires every presentation resource and waits for asynchronous owners.
    package func clear() async {
        beginNetworkRetirement()
        let customTasks = Array(customResourceTasks.values)
        for task in customTasks {
            task.cancel()
        }
        for resourceViewControllers in customResourceViewControllers.values {
            for resourceViewController in resourceViewControllers {
                resourceViewController.value?.synchronouslyResetForOwnerDeinit()
            }
        }
        customResourceStates.removeAll(keepingCapacity: false)
        customResourceTasks.removeAll(keepingCapacity: false)
        customResourceViewControllers.removeAll(keepingCapacity: false)
        customResourceGenerations.removeAll(keepingCapacity: false)
        customResourceRevisions.removeAll(keepingCapacity: false)
        contentCache.removeAll()
        networkResourceViewControllers.removeAll()
        networkContext = nil
        let retirementGeneration = networkRetirementGeneration
        let retirementTask = networkRetirementTask
        for task in customTasks {
            await task.value
        }
        await retirementTask?.value
        if networkRetirementGeneration == retirementGeneration {
            networkRetirementTask = nil
        }
    }

    private func retryCustomResource(
        for key: WebInspectorTab.ContentKey,
        session: WebInspectorSession,
        makeViewController: @escaping @MainActor (WebInspectorSession) async throws -> UIViewController
    ) {
        guard case .failed? = customResourceStates[key] else {
            return
        }
        startCustomResource(
            for: key,
            session: session,
            makeViewController: makeViewController
        )
    }

    private func startCustomResource(
        for key: WebInspectorTab.ContentKey,
        session: WebInspectorSession,
        makeViewController: @escaping @MainActor (WebInspectorSession) async throws -> UIViewController
    ) {
        if case .loading? = customResourceStates[key] {
            return
        }
        if case .ready? = customResourceStates[key] {
            return
        }
        let generation = advanceCustomResourceGeneration(for: key)
        customResourceStates[key] = .loading(generation: generation)
        advanceCustomResourceRevision(for: key)
        renderCustomResource(for: key)

        customResourceTasks[key] = Task { @MainActor [weak self, session] in
            do {
                let viewController = try await makeViewController(session)
                guard !Task.isCancelled else {
                    return
                }
                self?.completeCustomResource(
                    .success(viewController),
                    for: key,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.completeCustomResource(
                    .failure(error),
                    for: key,
                    generation: generation
                )
            }
        }
    }

    private func completeCustomResource(
        _ result: Result<UIViewController, any Error>,
        for key: WebInspectorTab.ContentKey,
        generation: UInt64
    ) {
        guard customResourceStates[key]?.generation == generation else {
            return
        }
        customResourceTasks[key] = nil
        switch result {
        case let .success(viewController):
            customResourceStates[key] = .ready(
                generation: generation,
                viewController: viewController
            )
        case let .failure(error):
            customResourceStates[key] = .failed(
                generation: generation,
                message: error.localizedDescription
            )
        }
        advanceCustomResourceRevision(for: key)
        renderCustomResource(for: key)
    }

    private func renderCustomResource(for key: WebInspectorTab.ContentKey) {
        customResourceViewControllers[key] = customResourceViewControllers[key]?.filter { box in
            guard let viewController = box.value else {
                return false
            }
            renderCustomResource(for: key, on: viewController)
            return true
        } ?? []
    }

    private func renderCustomResource(
        for key: WebInspectorTab.ContentKey,
        on viewController: CustomTabResourceViewController
    ) {
        let revision = customResourceRevisions[key] ?? 0
        switch customResourceStates[key] {
        case .none, .loading:
            viewController.showLoading(revision: revision)
        case let .ready(_, content):
            viewController.showReady(content, revision: revision)
        case let .failed(_, message):
            viewController.showFailure(message, revision: revision)
        }
    }

    @discardableResult
    private func advanceCustomResourceGeneration(
        for key: WebInspectorTab.ContentKey
    ) -> UInt64 {
        let generation = customResourceGenerations[key] ?? 0
        precondition(
            generation < UInt64.max,
            "Custom tab resource generation overflowed."
        )
        let nextGeneration = generation + 1
        customResourceGenerations[key] = nextGeneration
        return nextGeneration
    }

    private func advanceCustomResourceRevision(
        for key: WebInspectorTab.ContentKey
    ) {
        let revision = customResourceRevisions[key] ?? 0
        precondition(
            revision < UInt64.max,
            "Custom tab resource revision overflowed."
        )
        customResourceRevisions[key] = revision + 1
    }

    private func startNetworkResource(
        context: WebInspectorModelContext
    ) {
        guard case .idle = networkResourceState else {
            return
        }

        let generation = advanceNetworkResourceGeneration()
        networkResourceState = .loading(generation: generation)
        advanceNetworkResourceRevision()
        renderNetworkResource()

        let retirementTask = networkRetirementTask
        let makeNetworkPanelModel = makeNetworkPanelModel
        networkResourceTask = Task { @MainActor [weak self] in
            await retirementTask?.value
            guard self?.isCurrentNetworkResource(generation: generation) == true else {
                return
            }
            self?.networkRetirementTask = nil

            do {
                let model = try await makeNetworkPanelModel(context)
                guard let self,
                      isCurrentNetworkResource(generation: generation) else {
                    await model.retire()
                    return
                }
                networkResourceTask = nil
                networkResourceState = .ready(
                    generation: generation,
                    model: model
                )
                advanceNetworkResourceRevision()
                renderNetworkResource()
            } catch {
                guard let self,
                      isCurrentNetworkResource(generation: generation) else {
                    return
                }
                let message = error.localizedDescription
                networkResourceTask = nil
                networkResourceState = .failed(
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
        if case let .ready(_, model) = networkResourceState {
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
        generation: UInt64
    ) -> Bool {
        guard networkResourceGeneration == generation else {
            return false
        }
        switch networkResourceState {
        case let .loading(resourceGeneration):
            return resourceGeneration == generation
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
        case let .ready(_, model):
            viewController.showReady(model, revision: networkResourceRevision)
        case let .failed(_, message):
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
        guard case let .ready(_, model) = networkResourceState else {
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

    package func customResourceStatusForTesting(
        for key: WebInspectorTab.ContentKey
    ) -> CustomResourceStatus? {
        switch customResourceStates[key] {
        case .none:
            nil
        case .loading:
            .loading
        case .ready:
            .ready
        case let .failed(_, message):
            .failed(message)
        }
    }

    package func customReadyViewControllerForTesting(
        for key: WebInspectorTab.ContentKey
    ) -> UIViewController? {
        guard case let .ready(_, viewController) = customResourceStates[key] else {
            return nil
        }
        return viewController
    }

    package func waitForCustomResourceTaskForTesting(
        for key: WebInspectorTab.ContentKey
    ) async {
        await customResourceTasks[key]?.value
    }
    #endif
}
#endif
