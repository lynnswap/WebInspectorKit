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

    private enum ResourceFailureDisposition {
        case failed(String)
        case closed
    }

    private enum RequiredNetworkResourceError: Error {
        case connectionEnded
    }

    @MainActor
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
        private let failureDisposition: @MainActor (any Error)
            -> ResourceFailureDisposition
        private var task: Task<Void, Never>?

        init(
            makeValue: @escaping @MainActor () async throws -> Value,
            retireValue: @escaping @MainActor (Value) async -> Void,
            failureDisposition: @escaping @MainActor (any Error)
                -> ResourceFailureDisposition = { error in
                    if let commandError = error as? WebInspectorCommandError {
                        switch commandError {
                        case .connection, .containerClosed:
                            return .closed
                        case .staleIdentifier, .featureUnavailable, .targetChanged,
                            .rejected, .timedOut:
                            break
                        }
                    }
                    return .failed(error.localizedDescription)
                }
        ) {
            self.makeValue = makeValue
            self.retireValue = retireValue
            self.failureDisposition = failureDisposition
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
                    switch failureDisposition(error) {
                    case let .failed(message):
                        state = .failed(message)
                    case .closed:
                        state = .closed
                    }
                    onChange()
                }
            }
        }

        @discardableResult
        func restart(onChange: @escaping @MainActor () -> Void) -> Bool {
            guard case .closed = state else { return false }
            state = .idle
            start(onChange: onChange)
            return true
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

    private struct RetryTaskHandle {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum RequiredNetworkReadiness: Equatable, Sendable {
        case ready
        case connectionEnded
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
    private var domRetryTask: RetryTaskHandle?
    private var customRetryTasks: [
        WebInspectorTab.ContentKey: RetryTaskHandle
    ] = [:]
    private var containerStateTask: Task<Void, Never>?
    private var resourceAttachmentGeneration: WebInspectorAttachmentGeneration?

    #if DEBUG
    private let containerFailureRetirementPublisher =
        _WebInspectorStatePublisher<Int>(0)
    private let containerAttachmentRestartPublisher =
        _WebInspectorStatePublisher<Int>(0)
    #endif

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
        resourceAttachmentGeneration = Self.attachmentGeneration(
            in: context.modelContainer.state
        )
        containerStateTask = Task { @MainActor [weak self, container = context.modelContainer] in
            var states = container.stateUpdates.makeAsyncIterator()
            while let state = await states.next() {
                guard Task.isCancelled == false else { return }
                guard let self else { return }
                if await self.reconcileResources(with: state) == false {
                    return
                }
            }
        }
    }

    isolated deinit {
        domRetryTask?.task.cancel()
        for retryTask in customRetryTasks.values {
            retryTask.task.cancel()
        }
        containerStateTask?.cancel()
        #if DEBUG
        containerFailureRetirementPublisher.finish()
        containerAttachmentRestartPublisher.finish()
        #endif
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
        let domRetryTask = domRetryTask?.task
        let customRetryTasks = customRetryTasks.values.map(\.task)

        self.domResource = nil
        self.networkResource = nil
        self.customResources.removeAll(keepingCapacity: false)
        self.domRetryTask = nil
        self.customRetryTasks.removeAll(keepingCapacity: false)
        resetViewControllers()
        contentCache.removeAll()

        domRetryTask?.cancel()
        for retryTask in customRetryTasks {
            retryTask.cancel()
        }
        await domRetryTask?.value
        for retryTask in customRetryTasks {
            await retryTask.value
        }

        await domResource?.close {}
        await networkResource?.close {}
        for resource in customResources {
            await resource.close {}
        }
    }

    private func reconcileResources(
        with state: WebInspectorModelContainer.State
    ) async -> Bool {
        switch state {
        case let .attaching(generation), let .attached(generation):
            if let resourceAttachmentGeneration,
               resourceAttachmentGeneration != generation {
                await closeResources()
            }
            resourceAttachmentGeneration = generation
            restartResourcesAfterConnectionRecovery()
            return true
        case let .failed(generation, _):
            resourceAttachmentGeneration = generation
            await closeResources()
            #if DEBUG
            containerFailureRetirementPublisher.publish(
                containerFailureRetirementPublisher.current + 1
            )
            #endif
            return true
        case let .detaching(generation):
            resourceAttachmentGeneration = generation
            return true
        case .detached:
            return true
        case .closing, .closed:
            await closeResources()
            return false
        }
    }

    private static func attachmentGeneration(
        in state: WebInspectorModelContainer.State
    ) -> WebInspectorAttachmentGeneration? {
        switch state {
        case let .attaching(generation),
            let .attached(generation),
            let .detaching(generation),
            let .failed(generation, _):
            generation
        case .detached, .closing, .closed:
            nil
        }
    }

    private func closeResources() async {
        let domResource = domResource
        let networkResource = networkResource
        let customResources = customResources

        await domResource?.close { [weak self] in self?.renderDOM() }
        await networkResource?.close { [weak self] in self?.renderNetwork() }
        for (key, resource) in customResources {
            await resource.close { [weak self] in
                self?.renderCustomResource(for: key)
            }
        }
    }

    private func restartResourcesAfterConnectionRecovery() {
        var didRestartResource = false
        if domResource?.restart(onChange: { [weak self] in self?.renderDOM() }) == true {
            didRestartResource = true
        }
        if networkResource?.restart(onChange: { [weak self] in self?.renderNetwork() }) == true {
            didRestartResource = true
        }
        for (key, resource) in customResources {
            if resource.restart(onChange: { [weak self] in
                self?.renderCustomResource(for: key)
            }) {
                didRestartResource = true
            }
        }

        #if DEBUG
        if didRestartResource {
            containerAttachmentRestartPublisher.publish(
                containerAttachmentRestartPublisher.current + 1
            )
        }
        #endif
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
        precondition(
            context.modelContainer.configuration.enabledFeatures.contains(.network),
            "The built-in Network tab requires the Network feature."
        )
        return Resource(
            makeValue: { [context, makeNetworkPanelModel] in
                guard await Self.waitForRequiredNetwork(
                    in: context.modelContainer
                ) else {
                    throw RequiredNetworkResourceError.connectionEnded
                }
                do {
                    return try await makeNetworkPanelModel(context.modelContext)
                } catch is CancellationError {
                    throw RequiredNetworkResourceError.connectionEnded
                } catch {
                    guard Self.isTerminal(context.modelContainer.state) else {
                        preconditionFailure(
                            "Network panel construction failed while its required connection remained active: \(error)"
                        )
                    }
                    throw RequiredNetworkResourceError.connectionEnded
                }
            },
            retireValue: { await $0.retire() },
            failureDisposition: { error in
                guard error is RequiredNetworkResourceError else {
                    preconditionFailure(
                        "Required Network resource escaped its connection boundary: \(error)"
                    )
                }
                return .closed
            }
        )
    }

    private func retryDOM() {
        guard let resource = domResource,
              case .failed = resource.state,
              domRetryTask == nil else { return }
        let retryTaskID = UUID()
        let context = context
        let task = Task { @MainActor [weak self, resource] in
            defer { self?.finishDOMRetryTask(id: retryTaskID) }
            await context.modelContainer.dom.retry()
            guard Task.isCancelled == false,
                  let self,
                  self.domResource === resource else { return }
            resource.start { [weak self] in self?.renderDOM() }
        }
        domRetryTask = RetryTaskHandle(id: retryTaskID, task: task)
    }

    private func retryCustomResource(
        for key: WebInspectorTab.ContentKey,
        requiredFeatures: Set<WebInspectorFeatureID>
    ) {
        guard let resource = customResources[key],
              case .failed = resource.state,
              customRetryTasks[key] == nil else { return }
        let retryTaskID = UUID()
        let context = context
        let task = Task { @MainActor [weak self, resource] in
            defer {
                self?.finishCustomRetryTask(for: key, id: retryTaskID)
            }
            for feature in requiredFeatures {
                if feature == .dom {
                    await context.modelContainer.dom.retry()
                } else if feature == .consoleRuntime {
                    await context.modelContainer.console.retry()
                }
                guard Task.isCancelled == false else { return }
            }
            guard let self,
                  self.customResources[key] === resource else { return }
            resource.start { [weak self] in
                self?.renderCustomResource(for: key)
            }
        }
        customRetryTasks[key] = RetryTaskHandle(
            id: retryTaskID,
            task: task
        )
    }

    private func finishDOMRetryTask(id: UUID) {
        guard domRetryTask?.id == id else { return }
        domRetryTask = nil
    }

    private func finishCustomRetryTask(
        for key: WebInspectorTab.ContentKey,
        id: UUID
    ) {
        guard customRetryTasks[key]?.id == id else { return }
        customRetryTasks[key] = nil
    }

    private static func waitForFeatures(
        _ features: Set<WebInspectorFeatureID>,
        in container: WebInspectorModelContainer
    ) async throws {
        for feature in features {
            try await waitForFeature(feature, in: container)
        }
    }

    private static func waitForFeature(
        _ feature: WebInspectorFeatureID,
        in container: WebInspectorModelContainer
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var states = container.featureStateUpdates(for: feature)
                    .makeAsyncIterator()
                while let state = await states.next() {
                    try Task.checkCancellation()
                    switch state {
                    case .ready:
                        if case .attached = container.state {
                            return
                        }
                    case let .unavailable(_, error):
                        guard feature != .network else {
                            preconditionFailure(
                                "A required Network feature cannot become unavailable: \(error)"
                            )
                        }
                        throw WebInspectorCommandError.featureUnavailable(
                            feature,
                            error
                        )
                    case .disabled:
                        if case .attached = container.state,
                           container.configuration.enabledFeatures.contains(feature) == false {
                            throw WebInspectorTabFeatureError.disabled(feature)
                        }
                    case .synchronizing, .recovering:
                        continue
                    }
                }
                try Task.checkCancellation()
                throw WebInspectorCommandError.containerClosed
            }
            group.addTask {
                var states = container.stateUpdates.makeAsyncIterator()
                while let state = await states.next() {
                    try Task.checkCancellation()
                    switch state {
                    case .attached:
                        switch container.featureState(for: feature) {
                        case .ready:
                            return
                        case let .unavailable(_, error):
                            guard feature != .network else {
                                preconditionFailure(
                                    "A required Network feature cannot become unavailable: \(error)"
                                )
                            }
                            throw WebInspectorCommandError.featureUnavailable(
                                feature,
                                error
                            )
                        case .disabled:
                            if container.configuration.enabledFeatures.contains(feature) == false {
                                throw WebInspectorTabFeatureError.disabled(feature)
                            }
                        case .synchronizing, .recovering:
                            continue
                        }
                    case let .failed(_, failure):
                        throw WebInspectorCommandError.connection(failure)
                    case .closing, .closed:
                        throw WebInspectorCommandError.containerClosed
                    case .detached, .attaching, .detaching:
                        continue
                    }
                }
                try Task.checkCancellation()
                throw WebInspectorCommandError.containerClosed
            }
            guard try await group.next() != nil else {
                throw WebInspectorCommandError.containerClosed
            }
            group.cancelAll()
        }
    }

    private static func waitForRequiredNetwork(
        in container: WebInspectorModelContainer
    ) async -> Bool {
        await withTaskGroup(of: RequiredNetworkReadiness.self) { group in
            group.addTask {
                var states = container.featureStateUpdates(for: .network)
                    .makeAsyncIterator()
                while let state = await states.next() {
                    if Task.isCancelled {
                        return .connectionEnded
                    }
                    switch state {
                    case .ready:
                        if case .attached = container.state {
                            return .ready
                        }
                    case let .unavailable(_, error):
                        preconditionFailure(
                            "A required Network feature cannot become unavailable: \(error)"
                        )
                    case .disabled, .synchronizing, .recovering:
                        continue
                    }
                }
                return .connectionEnded
            }
            group.addTask {
                var states = container.stateUpdates.makeAsyncIterator()
                while let state = await states.next() {
                    if Task.isCancelled {
                        return .connectionEnded
                    }
                    switch state {
                    case .attached:
                        if case .ready = container.featureState(for: .network) {
                            return .ready
                        }
                    case .failed, .closing, .closed:
                        return .connectionEnded
                    case .detached, .attaching, .detaching:
                        continue
                    }
                }
                return .connectionEnded
            }
            let result = await group.next() ?? .connectionEnded
            group.cancelAll()
            return result == .ready
        }
    }

    private static func isTerminal(
        _ state: WebInspectorModelContainer.State
    ) -> Bool {
        switch state {
        case .failed, .closing, .closed:
            true
        case .detached, .attaching, .attached, .detaching:
            false
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
            viewController.showClosed()
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
            preconditionFailure(
                "Required Network resource published a local failure: \(message)"
            )
        case .closed:
            viewController.showClosed()
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
            viewController.showClosed()
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
        await domRetryTask?.task.value
        await domResource?.waitForAttempt()
    }
    package func waitForNetworkResourceTaskForTesting() async {
        await networkResource?.waitForAttempt()
    }
    package var containerFailureRetirementCountForTesting: Int {
        containerFailureRetirementPublisher.current
    }
    package func waitForContainerFailureRetirementForTesting(
        after baselineCount: Int
    ) async {
        var updates = containerFailureRetirementPublisher.updates()
            .makeAsyncIterator()
        while let count = await updates.next() {
            if count > baselineCount { return }
        }
    }
    package var containerAttachmentRestartCountForTesting: Int {
        containerAttachmentRestartPublisher.current
    }
    package func waitForContainerAttachmentRestartForTesting(
        after baselineCount: Int
    ) async {
        var updates = containerAttachmentRestartPublisher.updates()
            .makeAsyncIterator()
        while let count = await updates.next() {
            if count > baselineCount { return }
        }
    }
    package func waitForCustomResourceTaskForTesting(
        for key: WebInspectorTab.ContentKey
    ) async {
        await customRetryTasks[key]?.task.value
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
