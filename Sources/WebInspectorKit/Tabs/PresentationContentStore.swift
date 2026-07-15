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
        case failed(String, allowsRetry: Bool)
        case closed
    }

    @MainActor
    private final class Resource<Value> {
        private struct CloseTaskHandle {
            let id: UUID
            let task: Task<Void, Never>
        }

        enum State {
            case idle
            case loading
            case ready(Value)
            case failed(String, allowsRetry: Bool)
            case closed
        }

        private(set) var state: State = .idle
        private let makeValue: @MainActor () async throws -> Value
        private let retireValue: @MainActor (Value) async -> Void
        private let failureDisposition:
            @MainActor (any Error)
                -> ResourceFailureDisposition
        private var task: Task<Void, Never>?
        private var closeTask: CloseTaskHandle?

        init(
            makeValue: @escaping @MainActor () async throws -> Value,
            retireValue: @escaping @MainActor (Value) async -> Void,
            failureDisposition:
                @escaping @MainActor (any Error)
                -> ResourceFailureDisposition = { error in
                    if let commandError = error as? WebInspectorCommandError {
                        switch commandError {
                        case .connection, .containerClosed:
                            return .closed
                        case .featureUnsupported:
                            return .failed(
                                error.localizedDescription,
                                allowsRetry: false
                            )
                        case .staleIdentifier, .targetChanged, .rejected,
                            .timedOut:
                            break
                        }
                    }
                    if error is WebInspectorTabFeatureError {
                        return .failed(
                            error.localizedDescription,
                            allowsRetry: false
                        )
                    }
                    return .failed(error.localizedDescription, allowsRetry: true)
                }
        ) {
            self.makeValue = makeValue
            self.retireValue = retireValue
            self.failureDisposition = failureDisposition
        }

        isolated deinit {
            task?.cancel()
            closeTask?.task.cancel()
        }

        var status: ResourceStatus {
            switch state {
            case .idle: .idle
            case .loading: .loading
            case .ready: .ready
            case let .failed(message, _): .failed(message)
            case .closed: .closed
            }
        }

        func start(onChange: @escaping @MainActor () -> Void) {
            switch state {
            case .idle:
                break
            case .loading, .ready, .failed, .closed:
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
                        case .loading = state
                    else {
                        await retireValue(value)
                        return
                    }
                    task = nil
                    state = .ready(value)
                    onChange()
                } catch {
                    guard Task.isCancelled == false,
                          let self,
                        case .loading = state
                    else {
                        return
                    }
                    task = nil
                    switch failureDisposition(error) {
                    case let .failed(message, allowsRetry):
                        state = .failed(message, allowsRetry: allowsRetry)
                    case .closed:
                        state = .closed
                    }
                    onChange()
                }
            }
        }

        func retry(onChange: @escaping @MainActor () -> Void) {
            guard case .failed(_, allowsRetry: true) = state else { return }
            state = .idle
            start(onChange: onChange)
        }

        @discardableResult
        func restart(onChange: @escaping @MainActor () -> Void) -> Bool {
            guard case .closed = state, closeTask == nil else { return false }
            state = .idle
            start(onChange: onChange)
            return true
        }

        func close(onChange: @escaping @MainActor () -> Void) async {
            let handle: CloseTaskHandle
            if let closeTask {
                handle = closeTask
            } else {
                if case .closed = state {
                    return
                }

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

                let id = UUID()
                let retireValue = retireValue
                let task = Task { @MainActor in
                    await runningTask?.value
                    if let readyValue {
                        await retireValue(readyValue)
                    }
                }
                handle = CloseTaskHandle(id: id, task: task)
                closeTask = handle
            }

            await handle.task.value
            finishCloseTask(id: handle.id)
        }

        private func finishCloseTask(id: UUID) {
            guard closeTask?.id == id else { return }
            closeTask = nil
        }

        func readyValue() -> Value? {
            guard case let .ready(value) = state else { return nil }
            return value
        }

        func waitForAttempt() async {
            if let closeTask {
                await closeTask.task.value
            } else {
                await task?.value
            }
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

    package typealias NetworkPanelModelFactory =
        @MainActor (
            WebInspectorModelContext
    ) async throws -> NetworkPanelModel
    package typealias DOMPanelModelFactory =
        @MainActor (
            WebInspectorModelContext
    ) async throws -> DOMPanelModel

    private let context: WebInspectorTab.Context
    private let makeDOMPanelModel: DOMPanelModelFactory
    private let makeNetworkPanelModel: NetworkPanelModelFactory
    private let contentCache = WebInspectorTab.ContentCache()

    private var domResource: Resource<DOMPanelModel>?
    private var networkResource: Resource<NetworkPanelModel>?
    private var customResources: [WebInspectorTab.ContentKey: Resource<UIViewController>] = [:]
    private var customRetryTasks: [WebInspectorTab.ContentKey: RetryTaskHandle] = [:]
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
    private var customViewControllers: [WebInspectorTab.ContentKey: [WeakBox<CustomTabResourceViewController>]] =
        [:]

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
        makeReadyViewController:
            @escaping @MainActor (DOMPanelModel)
            -> UIViewController
    ) -> DOMTabResourceViewController {
        let resource = domResource ?? makeDOMResource()
        domResource = resource
        let viewController = DOMTabResourceViewController(
            makeReadyViewController: makeReadyViewController
        )
        domViewControllers.append(WeakBox(viewController))
        resource.start { [weak self] in self?.renderDOM() }
        renderDOM(on: viewController)
        return viewController
    }

    package func networkViewController(
        makeReadyViewController:
            @escaping @MainActor (NetworkPanelModel)
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
        makeViewController:
            @escaping @MainActor (WebInspectorTab.Context)
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
            self?.retryCustomResource(for: key)
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
        let customRetryTasks = customRetryTasks.values.map(\.task)

        self.domResource = nil
        self.networkResource = nil
        self.customResources.removeAll(keepingCapacity: false)
        self.customRetryTasks.removeAll(keepingCapacity: false)
        resetViewControllers()
        contentCache.removeAll()

        for retryTask in customRetryTasks {
            retryTask.cancel()
        }
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
                resourceAttachmentGeneration != generation
            {
                await closeResources()
            }
            resourceAttachmentGeneration = generation
            restartResourcesAfterAttachment()
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

    private func restartResourcesAfterAttachment() {
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

    private func retryCustomResource(
        for key: WebInspectorTab.ContentKey
    ) {
        guard let resource = customResources[key],
              case .failed = resource.state,
            customRetryTasks[key] == nil
        else { return }
        let retryTaskID = UUID()
        let task = Task { @MainActor [weak self, resource] in
            defer {
                self?.finishCustomRetryTask(for: key, id: retryTaskID)
            }
            guard let self,
                self.customResources[key] === resource
            else { return }
            resource.retry { [weak self] in
                self?.renderCustomResource(for: key)
            }
        }
        customRetryTasks[key] = RetryTaskHandle(
            id: retryTaskID,
            task: task
        )
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
                    case .disabled:
                        if case .attached = container.state,
                            container.configuration.enabledFeatures.contains(feature) == false
                        {
                            throw WebInspectorTabFeatureError.disabled(feature)
                        }
                    case .synchronizing:
                        continue
                    case let .unsupported(requirements):
                        throw WebInspectorTabFeatureError.unsupported(
                            feature,
                            requirements: requirements
                        )
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
                        case .disabled:
                            if container.configuration.enabledFeatures.contains(feature) == false {
                                throw WebInspectorTabFeatureError.disabled(feature)
                            }
                        case .synchronizing:
                            continue
                        case let .unsupported(requirements):
                            throw WebInspectorTabFeatureError.unsupported(
                                feature,
                                requirements: requirements
                            )
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
        case let .failed(message, _):
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
        case let .failed(message, _):
            viewController.showFailure(message)
        case .closed:
            viewController.showClosed()
        }
    }

    private func renderCustomResource(for key: WebInspectorTab.ContentKey) {
        customViewControllers[key] =
            customViewControllers[key]?.filter { box in
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
        case let .failed(message, allowsRetry):
            viewController.showFailure(
                message,
                allowsRetry: allowsRetry
            )
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
    case unsupported(WebInspectorFeatureID, requirements: [String])

    var errorDescription: String? {
        switch self {
        case let .disabled(feature):
            "Required feature is disabled: \(feature.name)"
        case let .unsupported(feature, requirements):
            "Required feature is unsupported: \(feature.name) "
                + "(\(requirements.joined(separator: ", ")))"
        }
    }
}
#endif
