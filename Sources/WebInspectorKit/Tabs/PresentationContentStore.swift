#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorUIDOM
import WebInspectorUINetwork

/// Owns the finite resources of one root inspector presentation.
@MainActor
package final class PresentationContentStore {
    package enum ResourceStatus: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
        case closed
    }

    private final class Resource<Value> {
        enum State {
            case idle
            case loading
            case ready(Value)
            case failed(String)
            case closed
        }

        private(set) var state: State = .idle
        private let makeValue: @MainActor () async throws -> Value
        private let retireValue: @MainActor (Value) async -> Void
        private var task: Task<Void, Never>?

        init(
            makeValue: @escaping @MainActor () async throws -> Value,
            retireValue: @escaping @MainActor (Value) async -> Void
        ) {
            self.makeValue = makeValue
            self.retireValue = retireValue
        }

        isolated deinit {
            task?.cancel()
        }

        var status: ResourceStatus {
            switch state {
            case .idle: .idle
            case .loading: .loading
            case .ready: .ready
            case let .failed(message): .failed(message)
            case .closed: .closed
            }
        }

        func start(onChange: @escaping @MainActor () -> Void) {
            switch state {
            case .idle, .failed:
                break
            case .loading, .ready, .closed:
                return
            }

            state = .loading
            onChange()
            let makeValue = makeValue
            let retireValue = retireValue
            task = Task { @MainActor [weak self] in
                do {
                    let value = try await makeValue()
                    guard Task.isCancelled == false,
                          let self,
                          case .loading = state else {
                        await retireValue(value)
                        return
                    }
                    task = nil
                    state = .ready(value)
                    onChange()
                } catch {
                    guard Task.isCancelled == false,
                          let self,
                          case .loading = state else {
                        return
                    }
                    task = nil
                    state = .failed(error.localizedDescription)
                    onChange()
                }
            }
        }

        func close(onChange: @escaping @MainActor () -> Void) async {
            guard case .closed = state else {
                let runningTask = task
                let readyValue: Value?
                if case let .ready(value) = state {
                    readyValue = value
                } else {
                    readyValue = nil
                }

                state = .closed
                task = nil
                runningTask?.cancel()
                onChange()
                await runningTask?.value
                if let readyValue {
                    await retireValue(readyValue)
                }
                return
            }
        }

        func readyValue() -> Value? {
            guard case let .ready(value) = state else { return nil }
            return value
        }

        func waitForAttempt() async {
            await task?.value
        }
    }

    private final class WeakBox<Value: AnyObject> {
        weak var value: Value?

        init(_ value: Value) {
            self.value = value
        }
    }

    package typealias NetworkPanelModelFactory = @MainActor (
        WebInspectorModelContext
    ) async throws -> NetworkPanelModel
    package typealias DOMPanelModelFactory = @MainActor (
        WebInspectorModelContext
    ) async throws -> DOMPanelModel

    private let context: WebInspectorTab.Context
    private let makeDOMPanelModel: DOMPanelModelFactory
    private let makeNetworkPanelModel: NetworkPanelModelFactory
    private let contentCache = WebInspectorTab.ContentCache()

    private var domResource: Resource<DOMPanelModel>?
    private var networkResource: Resource<NetworkPanelModel>?
    private var customResources: [
        WebInspectorTab.ContentKey: Resource<UIViewController>
    ] = [:]

    private var domViewControllers: [WeakBox<DOMTabResourceViewController>] = []
    private var networkViewControllers: [WeakBox<NetworkTabResourceViewController>] = []
    private var customViewControllers: [
        WebInspectorTab.ContentKey: [WeakBox<CustomTabResourceViewController>]
    ] = [:]

    package init(
        context: WebInspectorTab.Context,
        makeNetworkPanelModel: @escaping NetworkPanelModelFactory = {
            try await NetworkPanelModel.make(context: $0)
        },
        makeDOMPanelModel: @escaping DOMPanelModelFactory = {
            try await DOMPanelModel.make(context: $0)
        }
    ) {
        self.context = context
        self.makeDOMPanelModel = makeDOMPanelModel
        self.makeNetworkPanelModel = makeNetworkPanelModel
    }

    isolated deinit {
        for viewController in domViewControllers {
            viewController.value?.synchronouslyResetForOwnerDeinit()
        }
        for viewController in networkViewControllers {
            viewController.value?.synchronouslyResetForOwnerDeinit()
        }
        for viewControllers in customViewControllers.values {
            for viewController in viewControllers {
                viewController.value?.synchronouslyResetForOwnerDeinit()
            }
        }
        contentCache.removeAll()
    }

    package func viewController<Content: UIViewController>(
        for key: WebInspectorTab.ContentKey,
        make: () -> Content
    ) -> Content {
        contentCache.viewController(for: key, make: make)
    }

    package func domViewController(
        makeReadyViewController: @escaping @MainActor (DOMPanelModel)
            -> UIViewController
    ) -> DOMTabResourceViewController {
        let resource = domResource ?? makeDOMResource()
        domResource = resource
        let viewController = DOMTabResourceViewController(
            retryAction: { [weak self] in self?.retryDOM() },
            makeReadyViewController: makeReadyViewController
        )
        domViewControllers.append(WeakBox(viewController))
        resource.start { [weak self] in self?.renderDOM() }
        renderDOM(on: viewController)
        return viewController
    }

    package func networkViewController(
        makeReadyViewController: @escaping @MainActor (NetworkPanelModel)
            -> UIViewController
    ) -> NetworkTabResourceViewController {
        let resource = networkResource ?? makeNetworkResource()
        networkResource = resource
        let viewController = NetworkTabResourceViewController(
            retryAction: { [weak self] in self?.retryNetwork() },
            makeReadyViewController: makeReadyViewController
        )
        networkViewControllers.append(WeakBox(viewController))
        resource.start { [weak self] in self?.renderNetwork() }
        renderNetwork(on: viewController)
        return viewController
    }

    package func customViewController(
        for key: WebInspectorTab.ContentKey,
        context: WebInspectorTab.Context,
        requiredFeatures: Set<WebInspectorFeatureID>,
        makeViewController: @escaping @MainActor (WebInspectorTab.Context)
            async throws -> UIViewController
    ) -> CustomTabResourceViewController {
        let resource: Resource<UIViewController>
        if let existing = customResources[key] {
            resource = existing
        } else {
            resource = Resource(
                makeValue: {
                    try await Self.waitForFeatures(
                        requiredFeatures,
                        in: context.modelContainer
                    )
                    return try await makeViewController(context)
                },
                retireValue: { viewController in
                    viewController.webInspectorDetachFromContainerForReuse()
                }
            )
            customResources[key] = resource
        }

        let viewController = CustomTabResourceViewController { [weak self] in
            self?.retryCustomResource(
                for: key,
                requiredFeatures: requiredFeatures
            )
        }
        customViewControllers[key, default: []].append(WeakBox(viewController))
        resource.start { [weak self] in self?.renderCustomResource(for: key) }
        renderCustomResource(for: key, on: viewController)
        return viewController
    }

    package func clear() async {
        let domResource = domResource
        let networkResource = networkResource
        let customResources = Array(customResources.values)

        self.domResource = nil
        self.networkResource = nil
        self.customResources.removeAll(keepingCapacity: false)
        resetViewControllers()
        contentCache.removeAll()

        await domResource?.close {}
        await networkResource?.close {}
        for resource in customResources {
            await resource.close {}
        }
    }

    private func makeDOMResource() -> Resource<DOMPanelModel> {
        Resource(
            makeValue: { [context, makeDOMPanelModel] in
                try await Self.waitForFeatures(
                    [.dom],
                    in: context.modelContainer
                )
                return try await makeDOMPanelModel(context.modelContext)
            },
            retireValue: { await $0.retire() }
        )
    }

    private func makeNetworkResource() -> Resource<NetworkPanelModel> {
        Resource(
            makeValue: { [context, makeNetworkPanelModel] in
                try await Self.waitForFeatures(
                    [.network],
                    in: context.modelContainer
                )
                return try await makeNetworkPanelModel(context.modelContext)
            },
            retireValue: { await $0.retire() }
        )
    }

    private func retryDOM() {
        guard let resource = domResource,
              case .failed = resource.state else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await context.modelContainer.retryFeature(.dom)
            resource.start { [weak self] in self?.renderDOM() }
        }
    }

    private func retryNetwork() {
        guard let resource = networkResource,
              case .failed = resource.state else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await context.modelContainer.retryFeature(.network)
            resource.start { [weak self] in self?.renderNetwork() }
        }
    }

    private func retryCustomResource(
        for key: WebInspectorTab.ContentKey,
        requiredFeatures: Set<WebInspectorFeatureID>
    ) {
        guard let resource = customResources[key],
              case .failed = resource.state else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for feature in requiredFeatures {
                await context.modelContainer.retryFeature(feature)
            }
            resource.start { [weak self] in
                self?.renderCustomResource(for: key)
            }
        }
    }

    private static func waitForFeatures(
        _ features: Set<WebInspectorFeatureID>,
        in container: WebInspectorModelContainer
    ) async throws {
        for feature in features {
            var states = container.featureStateUpdates(for: feature)
                .makeAsyncIterator()
            var becameReady = false
            while let state = await states.next() {
                switch state {
                case .ready:
                    becameReady = true
                case .unavailable(_, let error):
                    throw WebInspectorCommandError.featureUnavailable(
                        feature,
                        error
                    )
                case .disabled:
                    throw WebInspectorTabFeatureError.disabled(feature)
                case .synchronizing, .recovering:
                    continue
                }
                break
            }
            guard becameReady else {
                throw WebInspectorCommandError.containerClosed
            }
        }
    }

    private func renderDOM() {
        domViewControllers = domViewControllers.filter { box in
            guard let viewController = box.value else { return false }
            renderDOM(on: viewController)
            return true
        }
    }

    private func renderDOM(on viewController: DOMTabResourceViewController) {
        guard let resource = domResource else {
            viewController.showLoading()
            return
        }
        switch resource.state {
        case .idle, .loading:
            viewController.showLoading()
        case let .ready(model):
            viewController.showReady(model)
        case let .failed(message):
            viewController.showFailure(message)
        case .closed:
            viewController.showLoading()
        }
    }

    private func renderNetwork() {
        networkViewControllers = networkViewControllers.filter { box in
            guard let viewController = box.value else { return false }
            renderNetwork(on: viewController)
            return true
        }
    }

    private func renderNetwork(
        on viewController: NetworkTabResourceViewController
    ) {
        guard let resource = networkResource else {
            viewController.showLoading()
            return
        }
        switch resource.state {
        case .idle, .loading:
            viewController.showLoading()
        case let .ready(model):
            viewController.showReady(model)
        case let .failed(message):
            viewController.showFailure(message)
        case .closed:
            viewController.showLoading()
        }
    }

    private func renderCustomResource(for key: WebInspectorTab.ContentKey) {
        customViewControllers[key] = customViewControllers[key]?.filter { box in
            guard let viewController = box.value else { return false }
            renderCustomResource(for: key, on: viewController)
            return true
        } ?? []
    }

    private func renderCustomResource(
        for key: WebInspectorTab.ContentKey,
        on viewController: CustomTabResourceViewController
    ) {
        guard let resource = customResources[key] else {
            viewController.showLoading()
            return
        }
        switch resource.state {
        case .idle, .loading:
            viewController.showLoading()
        case let .ready(content):
            viewController.showReady(content)
        case let .failed(message):
            viewController.showFailure(message)
        case .closed:
            viewController.showLoading()
        }
    }

    private func resetViewControllers() {
        for box in domViewControllers {
            box.value?.synchronouslyResetForOwnerDeinit()
        }
        for box in networkViewControllers {
            box.value?.synchronouslyResetForOwnerDeinit()
        }
        for boxes in customViewControllers.values {
            for box in boxes {
                box.value?.synchronouslyResetForOwnerDeinit()
            }
        }
        domViewControllers.removeAll(keepingCapacity: false)
        networkViewControllers.removeAll(keepingCapacity: false)
        customViewControllers.removeAll(keepingCapacity: false)
    }

    #if DEBUG
    package var contentCountForTesting: Int { contentCache.countForTesting }
    package var domResourceStatus: ResourceStatus {
        domResource?.status ?? .idle
    }
    package var networkResourceStatus: ResourceStatus {
        networkResource?.status ?? .idle
    }
    package var domPanelModelForTesting: DOMPanelModel? {
        domResource?.readyValue()
    }
    package var networkPanelModelForTesting: NetworkPanelModel? {
        networkResource?.readyValue()
    }
    package func waitForDOMResourceTaskForTesting() async {
        await domResource?.waitForAttempt()
    }
    package func waitForNetworkResourceTaskForTesting() async {
        await networkResource?.waitForAttempt()
    }
    package func waitForCustomResourceTaskForTesting(
        for key: WebInspectorTab.ContentKey
    ) async {
        await customResources[key]?.waitForAttempt()
    }
    #endif
}

private enum WebInspectorTabFeatureError: Error, LocalizedError {
    case disabled(WebInspectorFeatureID)

    var errorDescription: String? {
        switch self {
        case let .disabled(feature):
            "Required feature is disabled: \(feature.name)"
        }
    }
}
#endif
