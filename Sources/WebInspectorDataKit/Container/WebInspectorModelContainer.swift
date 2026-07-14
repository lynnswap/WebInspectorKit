import Dispatch
import Foundation
import Synchronization

/// Owns one physical/model session, its canonical store, and every context
/// issued for that session.
public final class WebInspectorModelContainer: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        public var enabledFeatures: Set<WebInspectorFeatureID>

        public init(
            enabledFeatures: Set<WebInspectorFeatureID> = [
                .dom, .network, .consoleRuntime,
            ]
        ) {
            self.enabledFeatures = enabledFeatures
        }
    }

    public enum State: Equatable, Sendable {
        case detached
        case attaching(generation: WebInspectorAttachmentGeneration)
        case attached(generation: WebInspectorAttachmentGeneration)
        case detaching(generation: WebInspectorAttachmentGeneration)
        case failed(
            generation: WebInspectorAttachmentGeneration,
            failure: WebInspectorConnectionFailure
        )
        case closing
        case closed
    }

    public let configuration: Configuration
    package let modelStore: WebInspectorModelStore
    package let modelStoreSink: WebInspectorModelStoreSink
    package let contextRegistry: WebInspectorModelContextRegistry
    package let featureRegistry: WebInspectorFeatureRegistry

    private let statePublisher = _WebInspectorStatePublisher<State>(.detached)
    private let closeReply = WebInspectorContextReply<Void>()
    @MainActor private weak var cachedMainContext: WebInspectorModelContext?
    @MainActor private weak var cachedClosedMainContext: WebInspectorModelContext?

    public var state: State { statePublisher.current }

    public var stateUpdates: WebInspectorStateUpdates<State> {
        statePublisher.updates()
    }

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        let store = WebInspectorModelStore(
            schemaRegistry: .empty,
            enabledFeatures: configuration.enabledFeatures
        )
        modelStore = store
        modelStoreSink = WebInspectorModelStoreSink(store: store)
        contextRegistry = WebInspectorModelContextRegistry(store: store)
        featureRegistry = WebInspectorFeatureRegistry(
            enabledFeatures: configuration.enabledFeatures
        )
    }

    package init(
        configuration: Configuration,
        schemaRegistry: WebInspectorModelSchemaRegistry
    ) {
        self.configuration = configuration
        let store = WebInspectorModelStore(
            schemaRegistry: schemaRegistry,
            enabledFeatures: configuration.enabledFeatures
        )
        modelStore = store
        modelStoreSink = WebInspectorModelStoreSink(store: store)
        contextRegistry = WebInspectorModelContextRegistry(store: store)
        featureRegistry = WebInspectorFeatureRegistry(
            enabledFeatures: configuration.enabledFeatures
        )
    }

    public static func == (
        lhs: WebInspectorModelContainer,
        rhs: WebInspectorModelContainer
    ) -> Bool {
        lhs === rhs
    }

    @MainActor
    public var mainContext: WebInspectorModelContext {
        if contextRegistry.isOpen {
            if let cachedMainContext,
                cachedMainContext.lifecycle.isOpen
            {
                return cachedMainContext
            }
            let context: WebInspectorModelContext
            do {
                context = try contextRegistry.issue(
                    for: self,
                    executor: .mainActor
                )
            } catch {
                return closedMainContext
            }
            cachedMainContext = context
            return context
        }
        return closedMainContext
    }

    public func makeModelActorBinding() throws
        -> WebInspectorModelActorBinding
    {
        let queue = DispatchSerialQueue(
            label: "WebInspectorDataKit.ModelContext.\(UUID().uuidString)"
        )
        let context = try contextRegistry.issue(
            for: self,
            executor: .serialQueue(queue)
        )
        return WebInspectorModelActorBinding(
            modelContext: context,
            serialQueue: queue
        )
    }

    /// Returns the current state for an arbitrary feature ID.
    public func featureState(
        for featureID: WebInspectorFeatureID
    ) -> WebInspectorFeatureState {
        featureRegistry.state(for: featureID)
    }

    /// Returns a last-value-first state stream for an arbitrary feature ID.
    public func featureStateUpdates(
        for featureID: WebInspectorFeatureID
    ) -> WebInspectorStateUpdates<WebInspectorFeatureState> {
        featureRegistry.updates(for: featureID)
    }

    /// Requests feature-local retry without creating another feature runner.
    public func retryFeature(_ featureID: WebInspectorFeatureID) async {
        await featureRegistry.retry(featureID)
    }

    /// Permanently closes context issuance and the canonical store.
    @MainActor
    public func close() async {
        switch statePublisher.current {
        case .closing, .closed:
            _ = try? await closeReply.value()
            return
        default:
            statePublisher.publish(.closing)
        }

        await contextRegistry.closeAll()
        await modelStore.close()
        featureRegistry.finish()
        cachedMainContext = nil
        statePublisher.publish(.closed)
        statePublisher.finish()
        closeReply.succeed(())
    }

    package func publishState(_ state: State) {
        statePublisher.publish(state)
    }

    @MainActor
    private var closedMainContext: WebInspectorModelContext {
        if let cachedClosedMainContext { return cachedClosedMainContext }
        let context = contextRegistry.makeClosedContext(
            for: self,
            executor: .mainActor
        )
        cachedClosedMainContext = context
        return context
    }
}
