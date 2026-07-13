import Foundation
import Observation
import Synchronization
import WebKit
import WebInspectorProxyKit

/// Failures caused by the current semantic model state rather than transport.
public enum WebInspectorModelError: Error, Equatable, Sendable {
    case detached
    case synchronizing
    case domainNotConfigured(WebInspectorModelContext.Domain)
    case staleModel
    case commandRejected(method: String, message: String)
}

/// The one audited unchecked boundary required to deliver a Sendable feed
/// record back to a runtime-selected actor.
///
/// This bridge owns no semantic state, terminal reason, task, feed, proxy, or
/// actor. Both references are weak, protected by one mutex, and the
/// context is dereferenced only inside one isolated-parameter hop. Those
/// invariants prevent it from becoming a second
/// model owner or a lifecycle edge.
private final class WebInspectorModelDeliveryBridge: @unchecked Sendable {
    enum ContainerOwnerDelivery: Equatable, Sendable {
        case applied(revision: UInt64)
        case closing
    }

    enum Request: Sendable {
        case prepareAttachment(token: UInt64)
        case prepareRecord(ConnectionModelFeedRecord, token: UInt64)
        case commit(WebInspectorModelContext.ReducerWorkResult, token: UInt64)
        case applyContainerTransaction(
            WebInspectorModelSchemaTransactionCommit
        )
        case beginClosingContainerProjection
        case finishClosingContainerProjection(WebInspectorModelSchemaClose)
        case accept(
            feed: ConnectionModelFeed,
            proxy: WebInspectorProxy,
            token: UInt64
        )
        case completeAttachment(token: UInt64)
        case prepareFailure(WebInspectorModelContext.Failure, token: UInt64)
    }

    enum Response: Sendable {
        case prepared(WebInspectorModelContext.PreparedReducerStep?)
        case committed(WebInspectorModelContext.ReducerCommitDecision)
        case accepted(Bool)
        case containerOwnerDelivery(ContainerOwnerDelivery)
    }

    private let mutex = Mutex(())
    private weak var actor: (any Actor)?
    private weak var context: WebInspectorModelContext?

    func bind(
        _ context: WebInspectorModelContext,
        isolation: isolated (any Actor)
    ) {
        mutex.withLock { _ in
            if let existingActor = actor {
                precondition(
                    existingActor === isolation,
                    "WebInspectorModelContext cannot move to another actor."
                )
            } else {
                actor = isolation
            }
            if let existingContext = self.context {
                precondition(
                    existingContext === context,
                    "A model delivery bridge cannot be rebound."
                )
            } else {
                self.context = context
            }
        }
    }

    func resolveActor() -> (any Actor)? {
        mutex.withLock { _ in actor }
    }

    func preconditionOwnerIsolation() {
        resolveActor()?.preconditionIsolated(
            "WebInspectorModelContext must be used by the actor that attached it."
        )
    }

    private func resolveContext(
        for isolation: any Actor
    ) -> WebInspectorModelContext? {
        mutex.withLock { _ -> WebInspectorModelContext? in
            guard let actor else {
                return nil
            }
            precondition(
                actor === isolation,
                "Model delivery ran on a foreign actor."
            )
            return context
        }
    }

    func deliver(
        _ request: Request,
        isolation: isolated (any Actor)
    ) -> Response? {
        guard let context = resolveContext(for: isolation) else {
            return nil
        }
        switch request {
        case let .prepareAttachment(token):
            return .prepared(context.prepareAttachment(token: token))
        case let .prepareRecord(record, token):
            return .prepared(context.prepare(record, token: token))
        case let .commit(result, token):
            return .committed(context.commit(result, token: token))
        case let .applyContainerTransaction(commit):
            return .containerOwnerDelivery(
                context.applyContainerTransaction(commit)
            )
        case .beginClosingContainerProjection:
            return .accepted(context.beginClosingContainerProjection())
        case let .finishClosingContainerProjection(close):
            return .accepted(
                context.finishClosingContainerProjection(close)
            )
        case let .accept(feed, proxy, token):
            return .accepted(
                context.accept(feed: feed, proxy: proxy, token: token)
            )
        case let .completeAttachment(token):
            return .accepted(context.completeAttachment(token: token))
        case let .prepareFailure(failure, token):
            return .prepared(context.prepareFailure(failure, token: token))
        }
    }
}

/// The identity-preserving model context for an inspected page.
///
/// A context owns observable DOM, Network, Console, Runtime, and CSS models.
/// It is non-Sendable and becomes permanently confined to the actor that first
/// calls ``attach(to:isolation:)``.
@Observable
public final class WebInspectorModelContext: Equatable, SendableMetatype {
    /// Compares contexts by object identity.
    public nonisolated static func == (
        lhs: WebInspectorModelContext,
        rhs: WebInspectorModelContext
    ) -> Bool {
        lhs === rhs
    }

    package struct DOMUndoRedoCommands {
        private weak var store: DOMStateStore?
        private let target: WebInspectorTarget?
        private let fallbackTarget: WebInspectorTarget?
        private let documentEpoch: Int

        fileprivate init(
            store: DOMStateStore,
            target: WebInspectorTarget?,
            fallbackTarget: WebInspectorTarget?,
            documentEpoch: Int
        ) {
            self.store = store
            self.target = target
            self.fallbackTarget = fallbackTarget
            self.documentEpoch = documentEpoch
        }

        package nonisolated(nonsending) func undo() async throws {
            try await undoRedoTarget().dom.undo()
        }

        package nonisolated(nonsending) func redo() async throws {
            try await undoRedoTarget().dom.redo()
        }

        private func undoRedoTarget() throws -> WebInspectorTarget {
            guard let store else {
                throw WebInspectorProxyError.disconnected("WebInspectorDataKit context was released before DOM undo/redo.")
            }
            return try store.undoRedoTarget(
                capturedTarget: target,
                fallbackTarget: fallbackTarget,
                documentEpoch: documentEpoch
            )
        }
    }

    package struct DOMDeletionPartialFailure: Error {
        package let deletedNodeCount: Int
        package let underlyingError: any Error

        package init(deletedNodeCount: Int, underlyingError: any Error) {
            self.deletedNodeCount = deletedNodeCount
            self.underlyingError = underlyingError
        }
    }

    /// A configured model domain. Construction is closed to the domains that
    /// the ordered ProxyKit feed can actually provide.
    public struct Domain: Hashable, Sendable {
        fileprivate let rawValue: UInt8

        private init(_ rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let dom = Domain(0)
        public static let network = Domain(1)
        public static let console = Domain(2)
        public static let runtime = Domain(3)
        public static let css = Domain(4)
    }

    public struct Configuration: Sendable {
        public let domains: Set<Domain>

        public init(
            domains: Set<Domain> = [.dom, .network, .console, .runtime, .css]
        ) {
            if domains.contains(.css) {
                self.domains = domains.union([.dom])
            } else {
                self.domains = domains
            }
        }
    }

    public struct PageGeneration: Hashable, Sendable {
        package let rawValue: UInt64

        package init(_ generation: WebInspectorPage.Generation) {
            rawValue = generation.rawValue
        }
    }

    public enum ConnectionFailure: Equatable, Sendable {
        case closed
        case pageUnavailable
        case protocolViolation(String)
        case transport(String)
    }

    public enum Failure: Error, Equatable, Sendable {
        case connection(ConnectionFailure)
        case bootstrap(domain: Domain, message: String)
    }

    public enum TransitionError: Error, Equatable, Sendable {
        case superseded
        case closed
    }

    /// The attachment state of a context.
    public enum State: Equatable, Sendable {
        case detached
        case attaching
        case synchronizing(PageGeneration)
        case attached
        case detaching
        case closed
        case failed(Failure)
    }

    /// A compact status value suitable for UI binding.
    public struct Status: Equatable, Sendable {
        /// The current attachment state.
        public let state: State

        /// The currently selected DOM node identity.
        public let selectedNodeID: DOMNode.ID?

        /// A Boolean value indicating whether WebKit inspect mode is enabled.
        public let isElementPickerEnabled: Bool
    }

    private enum DOMTargetAuthority {
        case awaiting(ModelDOMBindingEpoch)
        case ready(ModelDOMBindingEpoch)

        var epoch: ModelDOMBindingEpoch {
            switch self {
            case let .awaiting(epoch), let .ready(epoch):
                epoch
            }
        }
    }

    private struct BindingState {
        var generation: WebInspectorPage.Generation
        var lastSequence: UInt64?
        var targetSnapshotWasApplied: Bool
        var currentPageID: WebInspectorTarget.ID?
        var targets: [WebInspectorTarget.ID: ModelTarget]
        var navigationEpochs: [WebInspectorTarget.ID: ModelNavigationEpoch]
        var domAuthority: [WebInspectorTarget.ID: DOMTargetAuthority]
        var runtimeBindingEpochs: [WebInspectorTarget.ID: ModelRuntimeBindingEpoch]
        var consoleBindingEpochs: [WebInspectorTarget.ID: ModelConsoleBindingEpoch]
        var bootstrapSnapshotThrough: [ModelDomain: UInt64]
        var bootstrapCompletionThrough: [ModelDomain: UInt64]
        var completedDomains: Set<ModelDomain>
        var didSynchronize: Bool
    }

    private enum PendingReducerCommitAction {
        case none
        case failure(Failure)
        case synchronizationComplete(
            generation: WebInspectorPage.Generation,
            through: UInt64
        )
    }

    private struct AttachmentTransition {
        let token: UInt64
        let proxy: WebInspectorProxy
        let completion: ReplyPromise<Void>
    }

    private struct ContainerRegistrationBinding {
        let core: WebInspectorModelContainerCore
        let registrationID: WebInspectorModelContextRegistrationID
    }

    private struct PreparedContainerContext {
        let context: WebInspectorModelContext
        let startGate: ReplyPromise<Bool>
    }

    fileprivate enum InspectorSelectionOutcome: Sendable {
        case selected(
            nodeID: DOM.Node.ID?,
            expectedSelectionRevision: UInt64
        )
        case superseded
        case failed(Failure)
    }

    fileprivate enum ReducerWork: Sendable {
        case none
        case reset(
            network: NetworkRequestStore.IndexWork,
            console: ConsoleMessageStore.IndexWork,
            pageHighlightDOM: DOM?
        )
        case preparePageHighlightClear(DOM)
        case pageHighlightClear(DOM)
        case network(NetworkRequestStore.IndexWork)
        case console(ConsoleMessageStore.IndexWork)
        case networkAcknowledgement(NetworkRequestStore.IndexAcknowledgementWork)
        case consoleAcknowledgement(ConsoleMessageStore.IndexAcknowledgementWork)
        case acknowledgements(
            network: NetworkRequestStore.IndexAcknowledgementWork?,
            console: ConsoleMessageStore.IndexAcknowledgementWork?,
            pageHighlightDOM: DOM?
        )
        case inspectorSelection(
            dom: DOM,
            objectID: Runtime.RemoteObject.ID?,
            feed: ConnectionModelFeed,
            expectedSelectionRevision: UInt64
        )

        func run(commit: ReducerCommit) async -> ReducerWorkResult {
            switch self {
            case .none:
                return ReducerWorkResult(commit: commit, output: .none)
            case let .reset(network, console, pageHighlightDOM):
                let networkResult = await network.run()
                let consoleResult = await console.run()
                return ReducerWorkResult(
                    commit: commit,
                    output: .reset(
                        network: networkResult,
                        console: consoleResult,
                        pageHighlightDOM: pageHighlightDOM
                    )
                )
            case let .preparePageHighlightClear(dom):
                return ReducerWorkResult(
                    commit: commit,
                    output: .pageHighlightClear(dom)
                )
            case let .pageHighlightClear(dom):
                await Self.clearPageHighlight(using: dom)
                return ReducerWorkResult(commit: commit, output: .none)
            case let .network(work):
                return ReducerWorkResult(
                    commit: commit,
                    output: .network(await work.run())
                )
            case let .console(work):
                return ReducerWorkResult(
                    commit: commit,
                    output: .console(await work.run())
                )
            case let .networkAcknowledgement(work):
                await work.run()
                return ReducerWorkResult(commit: commit, output: .none)
            case let .consoleAcknowledgement(work):
                await work.run()
                return ReducerWorkResult(commit: commit, output: .none)
            case let .acknowledgements(network, console, pageHighlightDOM):
                await network?.run()
                await console?.run()
                await Self.clearPageHighlight(using: pageHighlightDOM)
                return ReducerWorkResult(commit: commit, output: .none)
            case let .inspectorSelection(
                dom,
                objectID,
                feed,
                expectedSelectionRevision
            ):
                let nodeID: DOM.Node.ID?
                if let objectID {
                    do {
                        nodeID = try await dom.requestNode(
                            forRemoteObject: objectID
                        )
                    } catch {
                        if WebInspectorModelContext.isPickerSupersession(error) {
                            return ReducerWorkResult(
                                commit: commit,
                                output: .inspectorSelection(.superseded)
                            )
                        }
                        let operationError = error
                        let failure: Failure
                        do {
                            try await feed.releaseElementPicker()
                            failure = WebInspectorModelContext.mapAttachmentFailure(
                                operationError
                            )
                        } catch {
                            failure = WebInspectorModelContext.mapAttachmentFailure(
                                WebInspectorScopeError(
                                    operationError: operationError,
                                    cleanupError: error
                                )
                            )
                        }
                        return ReducerWorkResult(
                            commit: commit,
                            output: .inspectorSelection(.failed(failure))
                        )
                    }
                } else {
                    nodeID = nil
                }
                do {
                    try await feed.releaseElementPicker()
                } catch {
                    return ReducerWorkResult(
                        commit: commit,
                        output: .inspectorSelection(.failed(
                            WebInspectorModelContext.mapAttachmentFailure(error)
                        ))
                    )
                }
                return ReducerWorkResult(
                    commit: commit,
                    output: .inspectorSelection(.selected(
                        nodeID: nodeID,
                        expectedSelectionRevision: expectedSelectionRevision
                    ))
                )
            }
        }

        private static func clearPageHighlight(using dom: DOM?) async {
            guard let dom else {
                return
            }
            do {
                try await dom.hideHighlight()
            } catch {
                WebInspectorDataKitLog.debug(
                    "DOM page highlight reset cleanup failed: \(String(describing: error))"
                )
            }
        }
    }

    fileprivate enum ReducerCommit: Sendable {
        case attachmentPrepared(token: UInt64)
        case record(token: UInt64)
    }

    fileprivate enum ReducerWorkOutput: Sendable {
        case none
        case reset(
            network: NetworkRequestStore.IndexResult,
            console: ConsoleMessageStore.IndexResult,
            pageHighlightDOM: DOM?
        )
        case pageHighlightClear(DOM)
        case network(NetworkRequestStore.IndexResult)
        case console(ConsoleMessageStore.IndexResult)
        case inspectorSelection(InspectorSelectionOutcome)
    }

    fileprivate struct PreparedReducerStep: Sendable {
        let work: ReducerWork
        let commit: ReducerCommit

        func run() async -> ReducerWorkResult {
            await work.run(commit: commit)
        }
    }

    fileprivate struct ReducerWorkResult: Sendable {
        let commit: ReducerCommit
        let output: ReducerWorkOutput
    }

    fileprivate struct ReducerCommitDecision: Sendable {
        let accepted: Bool
        let followup: ReducerWork?
        let shouldContinue: Bool
    }

    public let configuredDomains: Set<Domain>
    /// The current attachment state.
    public private(set) var state: State
    public private(set) var attachmentGeneration: UInt64
    public private(set) var pageGeneration: PageGeneration?

    @ObservationIgnored let cssInspectorBaselineStore: CSSInspectorBaselineStore
    @ObservationIgnored private let domState: DOMStateStore
    @ObservationIgnored private let runtimeState: RuntimeStateStore
    @ObservationIgnored private let networkRequests: NetworkRequestStore
    @ObservationIgnored private let consoleMessages: ConsoleMessageStore
    @ObservationIgnored private let deliveryBridge: WebInspectorModelDeliveryBridge
    @ObservationIgnored private var activeProxy: WebInspectorProxy?
    @ObservationIgnored private var activeFeed: ConnectionModelFeed?
    @ObservationIgnored private var binding: BindingState?
    @ObservationIgnored private var attachmentTransition: AttachmentTransition?
    @ObservationIgnored private var readinessCompletion: ReplyPromise<Void>?
    @ObservationIgnored private var attachmentTask: Task<Failure?, Never>?
    @ObservationIgnored private var cleanupTask: Task<Failure?, Never>?
    @ObservationIgnored private var driverTask: Task<Void, Never>?
    @ObservationIgnored private var containerRegistrationBinding:
        ContainerRegistrationBinding?
    @ObservationIgnored private var containerDriverTask: Task<Void, Never>?
    @ObservationIgnored private var containerReadiness: ReplyPromise<Void>?
    @ObservationIgnored private var appliedContainerRevision: UInt64?
    @ObservationIgnored private var containerProjectionIsClosing: Bool
    @ObservationIgnored private var didPrepareAttachmentReset: Bool
    @ObservationIgnored private var isTerminallyClosed: Bool
    @ObservationIgnored private var pendingReducerCommitAction: PendingReducerCommitAction
    @ObservationIgnored private var didCompleteInitialAttachment: Bool
    @ObservationIgnored private var ownsElementPickerLease: Bool
    @ObservationIgnored private var isElementPickerTransitioning: Bool

    /// The stable live DOM tree for the current document.
    public var domTree: DOMTreeController {
        get throws {
            try requireConfigured(.dom)
            return domState.rootTreeController()
        }
    }

    /// The current root DOM node, or `nil` while no document is loaded.
    public var rootDOMNode: DOMNode? {
        get throws {
            try requireConfigured(.dom)
            return domState.rootNode
        }
    }

    /// The currently selected DOM node.
    public var selectedDOMNode: DOMNode? {
        get throws {
            try requireConfigured(.dom)
            return domState.selectedNode
        }
    }

    /// A Boolean value indicating whether WebKit inspect mode is enabled.
    public var isElementPickerEnabled: Bool {
        get throws {
            try requireConfigured(.dom)
            return domState.isElementPickerEnabled
        }
    }

    /// Runtime execution contexts known to the current page.
    public var runtimeContexts: [RuntimeContext] {
        get throws {
            try requireConfigured(.runtime)
            return runtimeState.executionContexts
        }
    }

    @ObservationIgnored private var currentPage: WebInspectorTarget?

    @ObservationIgnored private let statusRelay: WebInspectorAsyncStreamRelay<Status>
    @ObservationIgnored package let fetchedResultsQueryCore: WebInspectorModelContextCore
    @ObservationIgnored package let modelSchemaContextCore:
        WebInspectorModelSchemaContextCore
    @ObservationIgnored private let modelSchemaOwnerRegistry:
        WebInspectorModelSchemaOwnerRegistry
    @ObservationIgnored private let fetchedResultsControllerRegistry:
        WebInspectorFetchedResultsControllerOwnerRegistry
    @ObservationIgnored private let fetchedResultsControllerRetirementOwner:
        WebInspectorFetchedResultsControllerRetirementOwner
    @ObservationIgnored private var persistentModelProjectionIsClosed: Bool

    public convenience init(configuration: Configuration = .init()) {
        self.init(
            configuration: configuration,
            modelSchemaRegistry: WebInspectorModelSchemaRegistry([]),
            configuredFetchedResultsModelTypeIDs: []
        )
    }

    package convenience init(
        configuration: Configuration = .init(),
        configuredFetchedResultsModelTypes: [any WebInspectorPersistentModel.Type],
        isolation: isolated (any Actor) = #isolation
    ) {
        self.init(
            configuration: configuration,
            modelSchemaRegistry: WebInspectorModelSchemaRegistry([]),
            configuredFetchedResultsModelTypeIDs: Set(
                configuredFetchedResultsModelTypes.map(ObjectIdentifier.init)
            )
        )
        bindOwner(isolation)
    }

    package convenience init(
        configuration: Configuration = .init(),
        modelSchemaRegistry: WebInspectorModelSchemaRegistry,
        isolation: isolated (any Actor) = #isolation
    ) {
        self.init(
            configuration: configuration,
            modelSchemaRegistry: modelSchemaRegistry,
            configuredFetchedResultsModelTypeIDs:
                modelSchemaRegistry.configuredModelTypeIDs
        )
        bindOwner(isolation)
    }

    private init(
        configuration: Configuration,
        modelSchemaRegistry: WebInspectorModelSchemaRegistry,
        configuredFetchedResultsModelTypeIDs: Set<ObjectIdentifier>
    ) {
        let modelSchemaContext = modelSchemaRegistry.makeContext()
        modelSchemaContextCore = modelSchemaContext.core
        modelSchemaOwnerRegistry = modelSchemaContext.owner
        fetchedResultsQueryCore = WebInspectorModelContextCore(
            configuredModelTypeIDs: configuredFetchedResultsModelTypeIDs
        )
        fetchedResultsControllerRegistry =
            WebInspectorFetchedResultsControllerOwnerRegistry(
                contextIdentity: fetchedResultsQueryCore.identity
            )
        fetchedResultsControllerRetirementOwner =
            WebInspectorFetchedResultsControllerRetirementOwner()
        persistentModelProjectionIsClosed = false
        configuredDomains = configuration.domains
        cssInspectorBaselineStore = CSSInspectorBaselineStore()
        domState = DOMStateStore()
        runtimeState = RuntimeStateStore()
        networkRequests = NetworkRequestStore()
        consoleMessages = ConsoleMessageStore()
        deliveryBridge = WebInspectorModelDeliveryBridge()
        state = .detached
        attachmentGeneration = 0
        pageGeneration = nil
        activeProxy = nil
        activeFeed = nil
        binding = nil
        attachmentTransition = nil
        readinessCompletion = nil
        attachmentTask = nil
        cleanupTask = nil
        driverTask = nil
        containerRegistrationBinding = nil
        containerDriverTask = nil
        containerReadiness = nil
        appliedContainerRevision = nil
        containerProjectionIsClosing = false
        didPrepareAttachmentReset = false
        isTerminallyClosed = false
        pendingReducerCommitAction = .none
        didCompleteInitialAttachment = false
        ownsElementPickerLease = false
        isElementPickerTransitioning = false
        currentPage = nil
        statusRelay = WebInspectorAsyncStreamRelay()
        modelSchemaOwnerRegistry.bind(to: self)
    }

    /// Returns the context-local model only when this context has already
    /// materialized the identifier.
    public func registeredModel<ID: WebInspectorPersistentIdentifier>(
        for id: ID
    ) -> ID.Model? {
        preconditionOwnerIsolation()
        return modelSchemaOwnerRegistry.registeredModel(
            for: id,
            owner: self
        )
    }

    /// Resolves a current persistent identifier into this context's stable
    /// Observable model instance.
    public func model<ID: WebInspectorPersistentIdentifier>(
        for id: ID
    ) -> ID.Model? {
        preconditionOwnerIsolation()
        return modelSchemaOwnerRegistry.model(
            for: id,
            owner: self
        )
    }

    package func modelSchemaOwnerResource<
        Model: WebInspectorPersistentModel,
        Resource: AnyObject
    >(
        for model: Model.Type,
        as resource: Resource.Type
    ) -> Resource? {
        preconditionOwnerIsolation()
        return modelSchemaOwnerRegistry.ownerResource(
            for: model,
            as: resource,
            owner: self
        )
    }

    /// Returns one actor-evaluated snapshot of matching persistent IDs.
    public nonisolated(nonsending) func fetchIdentifiers<
        Model: WebInspectorPersistentModel
    >(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model.ID] {
        preconditionOwnerIsolation()
        try await waitUntilContainerReady()
        guard persistentModelProjectionIsClosed == false else {
            throw WebInspectorModelContextQueryError.closed
        }
        do {
            return try await fetchedResultsQueryCore.fetchIdentifiers(
                Model.self,
                fetchDescriptor: descriptor
            )
        } catch WebInspectorFetchedResultsQueryError.closedRegistration {
            throw WebInspectorModelContextQueryError.closed
        }
    }

    /// Materializes one complete query snapshot in this context's identity
    /// graph before later source revisions can enter the query core.
    public nonisolated(nonsending) func fetch<
        Model: WebInspectorPersistentModel
    >(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model] {
        preconditionOwnerIsolation()
        try await waitUntilContainerReady()
        guard persistentModelProjectionIsClosed == false else {
            throw WebInspectorModelContextQueryError.closed
        }

        let claim: WebInspectorModelFetchClaim<Model>
        do {
            claim = try await fetchedResultsQueryCore.prepareModelFetch(
                Model.self,
                fetchDescriptor: descriptor
            )
        } catch WebInspectorFetchedResultsQueryError.closedRegistration {
            throw WebInspectorModelContextQueryError.closed
        }
        do {
            try Task.checkCancellation()
        } catch {
            await claim.abandon()
            throw error
        }
        guard persistentModelProjectionIsClosed == false,
            claim.wasAbandoned == false
        else {
            await claim.abandon()
            throw WebInspectorModelContextQueryError.closed
        }

        let models = claim.ids.map { id -> Model in
            guard let model = model(for: id) else {
                preconditionFailure(
                    "A one-shot fetch ID must resolve before its owner admission is released."
                )
            }
            return model
        }
        let resolution = await claim.complete()
        guard resolution == .activated else {
            throw WebInspectorModelContextQueryError.closed
        }
        return models
    }

    @discardableResult
    package func publish(
        _ commit: WebInspectorModelSchemaTransactionCommit
    ) -> Bool {
        preconditionOwnerIsolation()
        return commit.publish(
            on: modelSchemaOwnerRegistry,
            owner: self
        )
    }

    package func applyFetchedResultsControllerOwnerMutations(
        _ mutations: [WebInspectorFetchedResultsControllerOwnerMutationBatch]
    ) {
        preconditionOwnerIsolation()
        fetchedResultsControllerRegistry.apply(mutations)
    }

    package func installFetchedResultsController<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ controller: WebInspectorFetchedResultsController<Model, SectionName>,
        ownerID: WebInspectorFetchedResultsControllerOwnerID,
        lease: WebInspectorFetchedResultsControllerRegistrationLease
    ) throws {
        preconditionOwnerIsolation()
        guard persistentModelProjectionIsClosed == false else {
            throw WebInspectorFetchedResultsControllerError.closed
        }
        fetchedResultsControllerRegistry.install(
            controller,
            ownerID: ownerID,
            lease: lease
        )
    }

    package var isPersistentModelProjectionClosed: Bool {
        preconditionOwnerIsolation()
        return persistentModelProjectionIsClosed
    }

    package var fetchedResultsControllerOwnerCountForTesting: Int {
        preconditionOwnerIsolation()
        return fetchedResultsControllerRegistry.countForTesting
    }

    package func markFetchedResultsControllerClosing(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID
    ) {
        preconditionOwnerIsolation()
        fetchedResultsControllerRegistry.markClosing(ownerID)
    }

    package func removeFetchedResultsController(
        _ ownerID: WebInspectorFetchedResultsControllerOwnerID
    ) {
        preconditionOwnerIsolation()
        fetchedResultsControllerRegistry.remove(ownerID)
    }

    package func scheduleFetchedResultsControllerQueryRetirement<
        Model: WebInspectorPersistentModel,
        SectionName: Hashable & Sendable
    >(
        _ token: WebInspectorFetchedResultsQueryRegistrationToken<
            Model,
            SectionName
        >,
        publication: WebInspectorFetchedResultsQueryRegistration<
            Model,
            SectionName
        >.Publication
    ) {
        preconditionOwnerIsolation()
        let contextCore = fetchedResultsQueryCore
        fetchedResultsControllerRetirementOwner.submit {
            await contextCore.closeQuery(
                token,
                publication: publication
            )
        }
    }

    package nonisolated(nonsending)
    func waitForFetchedResultsControllerRetirementsForTesting() async {
        preconditionOwnerIsolation()
        await fetchedResultsControllerRetirementOwner.waitForCurrentTasks()
    }

    private nonisolated(nonsending) func closePersistentModelProjection() async {
        guard persistentModelProjectionIsClosed == false else {
            return
        }
        persistentModelProjectionIsClosed = true
        fetchedResultsControllerRegistry.closeAll()
        await fetchedResultsControllerRetirementOwner.close()
        await fetchedResultsQueryCore.close()
        modelSchemaContextCore.close().apply(
            on: modelSchemaOwnerRegistry,
            owner: self
        )
    }

    @MainActor
    public convenience init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init(),
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        self.init(configuration: configuration)
        let proxy = try await WebInspectorProxy(
            attachingTo: webView,
            configuration: proxyConfiguration
        )
        do {
            try await attach(to: proxy, isolation: MainActor.shared)
        } catch {
            await proxy.close()
            throw error
        }
    }

    package static func preview(
        configuration: Configuration = .init()
    ) -> WebInspectorModelContext {
        let context = WebInspectorModelContext(configuration: configuration)
        context.state = .attached
        return context
    }

    package static func mainContext(
        for core: WebInspectorModelContainerCore,
        isolation: isolated (any Actor)
    ) -> WebInspectorModelContext {
        let seed = core.mainContextSeed
        let prepared = prepareContainerContext(
            core: core,
            registrationID: seed.id,
            updates: seed.updates,
            isolation: isolation
        )
        switch seed.claimForMaterialization() {
        case .admitted:
            prepared.startGate.fulfill(.success(true))
        case .closed:
            prepared.context.containerProjectionIsClosing = true
            prepared.context.isTerminallyClosed = true
            prepared.context.state = .closed
            prepared.startGate.fulfill(.success(false))
        }
        return prepared.context
    }

    package static func customContext(
        for core: WebInspectorModelContainerCore,
        registration: WebInspectorModelContextRegistration,
        isolation: isolated (any Actor)
    ) -> WebInspectorModelContext? {
        let prepared = prepareContainerContext(
            core: core,
            registrationID: registration.id,
            updates: registration.updates,
            isolation: isolation
        )
        guard registration.claimForMaterialization() == .admitted else {
            prepared.context.containerProjectionIsClosing = true
            prepared.context.isTerminallyClosed = true
            prepared.context.state = .closed
            prepared.startGate.fulfill(.success(false))
            return nil
        }
        prepared.startGate.fulfill(.success(true))
        return prepared.context
    }

    private static func prepareContainerContext(
        core: WebInspectorModelContainerCore,
        registrationID: WebInspectorModelContextRegistrationID,
        updates: WebInspectorCanonicalModelUpdateSequence,
        isolation: isolated (any Actor)
    ) -> PreparedContainerContext {
        let domains = Set(core.configuredDomains.map(Self.domain))
        let context = WebInspectorModelContext(
            configuration: Configuration(domains: domains),
            modelSchemaRegistry: core.modelSchemaRegistry,
            configuredFetchedResultsModelTypeIDs:
                core.modelSchemaRegistry.configuredModelTypeIDs
        )
        context.bindOwner(isolation)
        context.containerRegistrationBinding = ContainerRegistrationBinding(
            core: core,
            registrationID: registrationID
        )
        let readiness = ReplyPromise<Void>()
        context.containerReadiness = readiness
        let startGate = ReplyPromise<Bool>()
        context.containerDriverTask = makeContainerDriverTask(
            core: core,
            registrationID: registrationID,
            updates: updates,
            startGate: startGate,
            readiness: readiness,
            contextCore: context.fetchedResultsQueryCore,
            retirementOwner: context.fetchedResultsControllerRetirementOwner,
            schemaCore: context.modelSchemaContextCore,
            bridge: context.deliveryBridge
        )
        return PreparedContainerContext(
            context: context,
            startGate: startGate
        )
    }

    package nonisolated(nonsending) func waitUntilContainerReady() async throws {
        preconditionOwnerIsolation()
        guard let containerReadiness else {
            return
        }
        try await containerReadiness.valueIgnoringCancellation()
    }

    package var appliedContainerRevisionForTesting: UInt64? {
        preconditionOwnerIsolation()
        return appliedContainerRevision
    }

    deinit {
        attachmentTask?.cancel()
        cleanupTask?.cancel()
        driverTask?.cancel()
        containerDriverTask?.cancel()
    }

    package var status: Status {
        preconditionOwnerIsolation()
        return Status(
            state: state,
            selectedNodeID: domState.selectedNode?.id,
            isElementPickerEnabled: domState.isElementPickerEnabled
        )
    }

    package var statusUpdates: AsyncStream<Status> {
        statusRelay.makeStream(initialElement: status)
    }

    /// Attaches the context to an exclusively owned ProxyKit connection.
    ///
    /// The call returns only after the ordered feed has applied its binding
    /// synchronization boundary. Cancelling this caller cancels only its wait;
    /// use ``detach()`` or ``close()`` to change resource state.
    public func attach(
        to proxy: WebInspectorProxy,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        precondition(
            containerRegistrationBinding == nil,
            "A container-vended context cannot own a Proxy connection."
        )
        bindOwner(isolation)
        switch state {
        case .closed:
            throw TransitionError.closed
        case .attached where activeProxy === proxy:
            return
        case .attaching, .synchronizing:
            if let transition = attachmentTransition,
               transition.proxy === proxy {
                try await transition.completion.value()
                return
            }
            if activeProxy === proxy, let readinessCompletion {
                try await readinessCompletion.value()
                return
            }
        case .detached, .detaching, .failed, .attached:
            break
        }

        let completion = beginAttachment(to: proxy)
        try await completion.value()
    }

    public nonisolated(nonsending) func detach() async {
        preconditionOwnerIsolation()
        if containerRegistrationBinding != nil {
            await closeContainerRegistration()
            return
        }
        await tearDown(terminal: false)
    }

    package nonisolated(nonsending) func detachIfAttached(
        to proxy: WebInspectorProxy
    ) async {
        preconditionOwnerIsolation()
        guard activeProxy === proxy else {
            return
        }
        await tearDown(terminal: false)
    }

    public nonisolated(nonsending) func close() async {
        preconditionOwnerIsolation()
        if containerRegistrationBinding != nil {
            await closeContainerRegistration()
            return
        }
        await closePersistentModelProjection()
        await tearDown(terminal: true)
    }

    private nonisolated(nonsending) func closeContainerRegistration() async {
        guard let binding = containerRegistrationBinding else {
            return
        }
        let task = containerDriverTask
        let shouldBeginCoreClose = containerProjectionIsClosing == false
        _ = beginClosingContainerProjection()
        if shouldBeginCoreClose {
            do {
                _ = try await binding.core.beginContextClose(
                    binding.registrationID
                )
            } catch WebInspectorModelContainerCoreError.closed {
                // The Container already completed the same terminal teardown.
            } catch {
                preconditionFailure(
                    "A model context close lost its Core registration: \(error)"
                )
            }
        }
        await task?.value
        containerDriverTask = nil
    }

    private func bindOwner(_ isolation: isolated (any Actor)) {
        deliveryBridge.bind(self, isolation: isolation)
    }

    package func preconditionOwnerIsolation() {
        deliveryBridge.preconditionOwnerIsolation()
    }

    fileprivate func applyContainerTransaction(
        _ commit: WebInspectorModelSchemaTransactionCommit
    ) -> WebInspectorModelDeliveryBridge.ContainerOwnerDelivery {
        guard
            containerRegistrationBinding != nil,
            containerProjectionIsClosing == false,
            isTerminallyClosed == false
        else {
            return .closing
        }
        let revision = commit.canonicalRevision
        if let appliedContainerRevision {
            precondition(
                appliedContainerRevision < revision,
                "A model context must apply canonical revisions monotonically."
            )
        }
        precondition(
            publish(commit),
            "A container schema transaction must publish exactly once."
        )
        appliedContainerRevision = revision
        return .applied(revision: revision)
    }

    fileprivate func beginClosingContainerProjection() -> Bool {
        guard containerRegistrationBinding != nil else {
            return false
        }
        guard persistentModelProjectionIsClosed == false else {
            return true
        }
        containerProjectionIsClosing = true
        persistentModelProjectionIsClosed = true
        fetchedResultsControllerRegistry.closeAll()
        return true
    }

    fileprivate func finishClosingContainerProjection(
        _ close: WebInspectorModelSchemaClose
    ) -> Bool {
        guard containerRegistrationBinding != nil else {
            return false
        }
        if persistentModelProjectionIsClosed == false {
            _ = beginClosingContainerProjection()
        }
        precondition(
            persistentModelProjectionIsClosed,
            "A container projection must enter closing before owner teardown."
        )
        close.apply(
            on: modelSchemaOwnerRegistry,
            owner: self
        )
        if isTerminallyClosed == false {
            isTerminallyClosed = true
            transition(to: .closed)
        }
        containerDriverTask = nil
        return true
    }

    private func beginAttachment(
        to proxy: WebInspectorProxy
    ) -> ReplyPromise<Void> {
        precondition(!isTerminallyClosed, "A closed model context cannot attach.")
        let token = advanceAttachmentToken()
        readinessCompletion?.fulfill(.failure(TransitionError.superseded))
        attachmentTransition?.completion.fulfill(.failure(TransitionError.superseded))

        let previousAttachmentTask = attachmentTask
        let previousDriverTask = driverTask
        let previousFeed = activeFeed
        let previousProxy = activeProxy
        previousAttachmentTask?.cancel()
        previousDriverTask?.cancel()
        attachmentTask = nil
        driverTask = nil
        activeFeed = nil
        activeProxy = nil
        currentPage = nil
        binding = nil
        pageGeneration = nil
        didPrepareAttachmentReset = false
        pendingReducerCommitAction = .none
        ownsElementPickerLease = false
        isElementPickerTransitioning = false

        let cleanup = Self.makeCleanupTask(
            after: cleanupTask,
            attachmentTask: previousAttachmentTask,
            driverTask: previousDriverTask,
            feed: previousFeed,
            proxy: previousProxy
        )
        cleanupTask = cleanup

        let completion = ReplyPromise<Void>()
        attachmentTransition = AttachmentTransition(
            token: token,
            proxy: proxy,
            completion: completion
        )
        readinessCompletion = completion
        transition(to: .attaching)

        let configuredDomains = configuredModelDomains
        let bridge = deliveryBridge
        let task = Self.makeAttachmentTask(
            cleanup: cleanup,
            proxy: proxy,
            configuredDomains: configuredDomains,
            token: token,
            bridge: bridge
        )
        attachmentTask = task
        return completion
    }

    private nonisolated static func makeAttachmentTask(
        cleanup: Task<Failure?, Never>?,
        proxy: WebInspectorProxy,
        configuredDomains: Set<ModelDomain>,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) -> Task<Failure?, Never> {
        Task.detached(priority: .userInitiated) {
            await runAttachment(
                cleanup: cleanup,
                proxy: proxy,
                configuredDomains: configuredDomains,
                token: token,
                bridge: bridge
            )
        }
    }

    private nonisolated static func runAttachment(
        cleanup: Task<Failure?, Never>?,
        proxy: WebInspectorProxy,
        configuredDomains: Set<ModelDomain>,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async -> Failure? {
        if let cleanupFailure = await cleanup?.value {
            await failAttachment(
                cleanupFailure,
                token: token,
                bridge: bridge
            )
            return nil
        }
        guard !Task.isCancelled,
              let preparation = await prepareAttachmentStep(
                  token: token,
                  bridge: bridge
              ) else {
            return nil
        }
        let preparationResult = await preparation.run()
        let preparationCommit = await commit(
            preparationResult,
            token: token,
            bridge: bridge
        )
        guard preparationCommit.accepted, !Task.isCancelled else {
            return nil
        }
        if let followup = preparationCommit.followup {
            _ = await followup.run(commit: .record(token: token))
        }

        let registrationWasAccepted = Mutex(false)
        do {
            _ = try await proxy.openModelFeed(
                configuredDomains: configuredDomains,
                onRegistered: { feed in
                    guard !Task.isCancelled else {
                        return false
                    }
                    let accepted = await accept(
                        feed: feed,
                        proxy: proxy,
                        token: token,
                        bridge: bridge
                    )
                    registrationWasAccepted.withLock { value in
                        value = accepted
                    }
                    return accepted
                }
            )
            await completeAttachment(token: token, bridge: bridge)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            if registrationWasAccepted.withLock({ $0 }) {
                await completeAttachment(token: token, bridge: bridge)
                return nil
            }
            await failAttachment(
                mapAttachmentFailure(error),
                token: token,
                bridge: bridge
            )
            return nil
        }
    }

    private static func prepareAttachmentStep(
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async -> PreparedReducerStep? {
        guard let owner = bridge.resolveActor() else {
            return nil
        }
        guard case let .prepared(step)? = await bridge.deliver(
            .prepareAttachment(token: token),
            isolation: owner
        ) else {
            return nil
        }
        return step
    }

    private static func prepareRecordStep(
        _ record: ConnectionModelFeedRecord,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async -> PreparedReducerStep? {
        guard let owner = bridge.resolveActor() else {
            return nil
        }
        guard case let .prepared(step)? = await bridge.deliver(
            .prepareRecord(record, token: token),
            isolation: owner
        ) else {
            return nil
        }
        return step
    }

    private static func commit(
        _ result: ReducerWorkResult,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async -> ReducerCommitDecision {
        guard let owner = bridge.resolveActor() else {
            return ReducerCommitDecision(
                accepted: false,
                followup: nil,
                shouldContinue: false
            )
        }
        guard case let .committed(decision)? = await bridge.deliver(
            .commit(result, token: token),
            isolation: owner
        ) else {
            return ReducerCommitDecision(
                accepted: false,
                followup: nil,
                shouldContinue: false
            )
        }
        return decision
    }

    private static func accept(
        feed: ConnectionModelFeed,
        proxy: WebInspectorProxy,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async -> Bool {
        guard let owner = bridge.resolveActor() else {
            return false
        }
        guard case let .accepted(accepted)? = await bridge.deliver(
            .accept(feed: feed, proxy: proxy, token: token),
            isolation: owner
        ) else {
            return false
        }
        return accepted
    }

    private static func completeAttachment(
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async {
        guard let owner = bridge.resolveActor() else {
            return
        }
        _ = await bridge.deliver(
            .completeAttachment(token: token),
            isolation: owner
        )
    }

    private static func failAttachment(
        _ failure: Failure,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async {
        guard let step = await prepareFailureStep(
            failure,
            token: token,
            bridge: bridge
        ) else {
            return
        }
        let result = await step.run()
        let decision = await commit(result, token: token, bridge: bridge)
        if let followup = decision.followup {
            _ = await followup.run(commit: .record(token: token))
        }
    }

    private static func prepareFailureStep(
        _ failure: Failure,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async -> PreparedReducerStep? {
        guard let owner = bridge.resolveActor() else {
            return nil
        }
        guard case let .prepared(step)? = await bridge.deliver(
            .prepareFailure(failure, token: token),
            isolation: owner
        ) else {
            return nil
        }
        return step
    }

    fileprivate func prepareAttachment(
        token: UInt64
    ) -> PreparedReducerStep? {
        guard attachmentTransition?.token == token else {
            return nil
        }
        currentPage = nil
        binding = nil
        pageGeneration = nil
        let resetWork = prepareSemanticReset()
        return PreparedReducerStep(
            work: resetWork,
            commit: .attachmentPrepared(token: token)
        )
    }

    fileprivate func accept(
        feed: ConnectionModelFeed,
        proxy: WebInspectorProxy,
        token: UInt64
    ) -> Bool {
        guard attachmentTransition?.token == token,
              !isTerminallyClosed else {
            return false
        }
        activeProxy = proxy
        activeFeed = feed

        let records = feed.records
        let bridge = deliveryBridge
        driverTask = Self.makeDriverTask(
            records,
            token: token,
            bridge: bridge
        )
        return true
    }

    fileprivate func completeAttachment(token: UInt64) -> Bool {
        guard attachmentTransition?.token == token else {
            return false
        }
        attachmentTask = nil
        return true
    }

    private nonisolated static func makeContainerDriverTask(
        core: WebInspectorModelContainerCore,
        registrationID: WebInspectorModelContextRegistrationID,
        updates: WebInspectorCanonicalModelUpdateSequence,
        startGate: ReplyPromise<Bool>,
        readiness: ReplyPromise<Void>,
        contextCore: WebInspectorModelContextCore,
        retirementOwner: WebInspectorFetchedResultsControllerRetirementOwner,
        schemaCore: WebInspectorModelSchemaContextCore,
        bridge: WebInspectorModelDeliveryBridge
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            await driveContainerRegistration(
                core: core,
                registrationID: registrationID,
                updates: updates,
                startGate: startGate,
                readiness: readiness,
                contextCore: contextCore,
                retirementOwner: retirementOwner,
                schemaCore: schemaCore,
                bridge: bridge
            )
        }
    }

    private static func driveContainerRegistration(
        core: WebInspectorModelContainerCore,
        registrationID: WebInspectorModelContextRegistrationID,
        updates: WebInspectorCanonicalModelUpdateSequence,
        startGate: ReplyPromise<Bool>,
        readiness: ReplyPromise<Void>,
        contextCore: WebInspectorModelContextCore,
        retirementOwner: WebInspectorFetchedResultsControllerRetirementOwner,
        schemaCore: WebInspectorModelSchemaContextCore,
        bridge: WebInspectorModelDeliveryBridge
    ) async {
        guard (try? await startGate.valueIgnoringCancellation()) == true else {
            await beginClosingContainerProjection(bridge: bridge)
            await retirementOwner.close()
            await contextCore.close()
            let schemaClose = schemaCore.close()
            await finishClosingContainerProjection(
                schemaClose,
                bridge: bridge
            )
            readiness.fulfill(.success(()))
            return
        }
        var terminalFailure: (any Error)?
        do {
            try await core.activateContext(registrationID)
            var iterator = updates.makeAsyncIterator()
            var appliedRevision: UInt64?
            while let update = await iterator.next() {
                let transaction: WebInspectorModelSchemaTransaction
                switch update {
                case let .initial(revision, snapshot):
                    precondition(
                        appliedRevision == nil,
                        "A container context can apply initial schema state only once."
                    )
                    transaction = schemaCore.initial(
                        at: revision,
                        snapshot: snapshot
                    )
                case let .changes(fromRevision, toRevision, changes):
                    precondition(
                        appliedRevision == fromRevision
                            && toRevision == fromRevision + 1,
                        "A container context requires contiguous canonical changes."
                    )
                    transaction = schemaCore.changes(
                        at: toRevision,
                        transaction: changes
                    )
                case let .resetRequired(latestRevision, token):
                    let rebase = try await core.rebaseContext(
                        token,
                        for: registrationID
                    )
                    precondition(
                        latestRevision <= rebase.revision,
                        "A container rebase cannot precede its advertised canonical revision."
                    )
                    switch rebase.disposition {
                    case .initial:
                        precondition(
                            appliedRevision == nil,
                            "Only an uninitialized context can consume an initial rebase."
                        )
                        transaction = schemaCore.initial(
                            at: rebase.revision,
                            snapshot: rebase.snapshot
                        )
                    case .reset:
                        precondition(
                            appliedRevision.map { $0 < rebase.revision } == true,
                            "A context reset must advance established schema state."
                        )
                        transaction = schemaCore.reset(
                            at: rebase.revision,
                            snapshot: rebase.snapshot
                        )
                    }
                }

                let commit = try await transaction.stage(on: contextCore)
                let delivery = await applyContainerTransaction(
                    commit,
                    bridge: bridge
                )
                guard case let .applied(revision) = delivery else {
                    _ = await commit.abort(
                        throwing: WebInspectorModelContextQueryError.closed
                    )
                    break
                }
                precondition(
                    revision == transaction.canonicalRevision,
                    "Owner delivery acknowledged a different canonical revision."
                )
                appliedRevision = revision
                try await core.acknowledgeContext(
                    registrationID,
                    through: revision
                )
                readiness.fulfill(.success(()))
            }
        } catch let error {
            if let coreError = error as? WebInspectorModelContainerCoreError,
                coreError == .closed
            {
                // Container teardown owns the same terminal boundary.
            } else if error is CancellationError {
                // Context release cancels only this registration driver.
            } else {
                terminalFailure = error
            }
        }

        await beginClosingContainerProjection(bridge: bridge)
        await retirementOwner.close()
        await contextCore.close()
        let schemaClose = schemaCore.close()
        await finishClosingContainerProjection(
            schemaClose,
            bridge: bridge
        )
        _ = await core.unregisterContext(registrationID)
        if let terminalFailure {
            readiness.fulfill(.failure(terminalFailure))
            preconditionFailure(
                "A model context subscription violated its Core contract: \(terminalFailure)"
            )
        }
        readiness.fulfill(.success(()))
    }

    private static func applyContainerTransaction(
        _ commit: WebInspectorModelSchemaTransactionCommit,
        bridge: WebInspectorModelDeliveryBridge
    ) async -> WebInspectorModelDeliveryBridge.ContainerOwnerDelivery {
        guard let owner = bridge.resolveActor() else {
            return .closing
        }
        guard case let .containerOwnerDelivery(delivery)? = await bridge.deliver(
            .applyContainerTransaction(commit),
            isolation: owner
        ) else {
            return .closing
        }
        return delivery
    }

    private static func beginClosingContainerProjection(
        bridge: WebInspectorModelDeliveryBridge
    ) async {
        guard let owner = bridge.resolveActor() else {
            return
        }
        _ = await bridge.deliver(
            .beginClosingContainerProjection,
            isolation: owner
        )
    }

    private static func finishClosingContainerProjection(
        _ close: WebInspectorModelSchemaClose,
        bridge: WebInspectorModelDeliveryBridge
    ) async {
        guard let owner = bridge.resolveActor() else {
            return
        }
        _ = await bridge.deliver(
            .finishClosingContainerProjection(close),
            isolation: owner
        )
    }

    private nonisolated static func makeDriverTask(
        _ records: ConnectionModelFeedRecords,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            await drive(records, token: token, bridge: bridge)
        }
    }

    private static func drive(
        _ records: ConnectionModelFeedRecords,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async {
        do {
            for try await record in records {
                try Task.checkCancellation()
                guard let step = await prepareRecordStep(
                    record,
                    token: token,
                    bridge: bridge
                ) else {
                    return
                }
                let result = await step.run()
                let decision = await commit(
                    result,
                    token: token,
                    bridge: bridge
                )
                guard decision.accepted else {
                    return
                }
                if let followup = decision.followup {
                    _ = await followup.run(commit: .record(token: token))
                }
                guard decision.shouldContinue else {
                    return
                }
            }
            guard !Task.isCancelled else {
                return
            }
            await finishDriver(
                .connection(.closed),
                token: token,
                bridge: bridge
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }
            await finishDriver(
                mapAttachmentFailure(error),
                token: token,
                bridge: bridge
            )
        }
    }

    private static func finishDriver(
        _ failure: Failure,
        token: UInt64,
        bridge: WebInspectorModelDeliveryBridge
    ) async {
        await failAttachment(failure, token: token, bridge: bridge)
    }

    fileprivate func commit(
        _ result: ReducerWorkResult,
        token: UInt64
    ) -> ReducerCommitDecision {
        guard attachmentTransition?.token == token else {
            return ReducerCommitDecision(
                accepted: false,
                followup: nil,
                shouldContinue: false
            )
        }

        let followup: ReducerWork?
        var shouldContinue = true
        switch result.output {
        case .none:
            followup = nil
        case let .reset(networkResult, consoleResult, pageHighlightDOM):
            followup = .acknowledgements(
                network: networkRequests.commit(networkResult),
                console: consoleMessages.commit(consoleResult),
                pageHighlightDOM: pageHighlightDOM
            )
        case let .pageHighlightClear(dom):
            followup = .pageHighlightClear(dom)
        case let .network(networkResult):
            followup = networkRequests.commit(
                networkResult
            ).map(ReducerWork.networkAcknowledgement)
        case let .console(consoleResult):
            followup = consoleMessages.commit(
                consoleResult
            ).map(ReducerWork.consoleAcknowledgement)
        case let .inspectorSelection(outcome):
            switch outcome {
            case .superseded:
                followup = nil
            case let .selected(nodeID, expectedSelectionRevision):
                ownsElementPickerLease = false
                isElementPickerTransitioning = false
                if domState.selectionRevision == expectedSelectionRevision,
                   let nodeID {
                    applyDOMStateEffects(
                        domState.apply(.inspect(nodeID), modelContext: self)
                    )
                } else {
                    applyDOMStateEffects(
                        domState.setElementPickerEnabled(false)
                    )
                }
                followup = nil
            case let .failed(failure):
                ownsElementPickerLease = false
                isElementPickerTransitioning = false
                pendingReducerCommitAction = .failure(failure)
                followup = prepareSemanticReset()
                shouldContinue = false
            }
        }

        switch result.commit {
        case let .attachmentPrepared(expectedToken):
            guard expectedToken == token else {
                return ReducerCommitDecision(
                    accepted: false,
                    followup: nil,
                    shouldContinue: false
                )
            }
            didPrepareAttachmentReset = true
        case let .record(expectedToken):
            guard expectedToken == token else {
                return ReducerCommitDecision(
                    accepted: false,
                    followup: nil,
                    shouldContinue: false
                )
            }
            finishPreparedRecord()
        }
        return ReducerCommitDecision(
            accepted: true,
            followup: followup,
            shouldContinue: shouldContinue
        )
    }

    private func transitionToFailure(
        _ failure: Failure,
        token: UInt64
    ) {
        guard attachmentTransition?.token == token else {
            return
        }
        invalidateBindingState()
        attachmentTransition?.completion.fulfill(.failure(failure))
        readinessCompletion?.fulfill(.failure(failure))
        readinessCompletion = nil
        transition(to: .failed(failure))
    }

    private nonisolated(nonsending) func tearDown(terminal: Bool) async {
        preconditionOwnerIsolation()
        if isTerminallyClosed {
            return
        }
        let token = advanceAttachmentToken()
        if terminal {
            isTerminallyClosed = true
        }
        let transitionError: TransitionError = terminal ? .closed : .superseded
        attachmentTransition?.completion.fulfill(.failure(transitionError))
        readinessCompletion?.fulfill(.failure(transitionError))
        attachmentTransition = nil
        readinessCompletion = nil
        transition(to: .detaching)

        let attachmentTask = attachmentTask
        let driverTask = driverTask
        let feed = activeFeed
        let proxy = activeProxy
        attachmentTask?.cancel()
        driverTask?.cancel()
        self.attachmentTask = nil
        self.driverTask = nil
        activeFeed = nil
        activeProxy = nil
        invalidateBindingState()

        let resetStep = PreparedReducerStep(
            work: prepareSemanticReset(),
            commit: .attachmentPrepared(token: token)
        )
        let resetResult = await resetStep.run()
        let resetFollowup = commitDetachedReset(
            resetResult,
            token: token
        )
        if let resetFollowup {
            _ = await resetFollowup.run(commit: .record(token: token))
        }

        let cleanup = Self.makeCleanupTask(
            after: cleanupTask,
            attachmentTask: attachmentTask,
            driverTask: driverTask,
            feed: feed,
            proxy: proxy
        )
        cleanupTask = cleanup
        let cleanupFailure = await cleanup?.value

        guard attachmentGeneration == token else {
            return
        }
        cleanupTask = nil
        if let cleanupFailure {
            transition(to: .failed(cleanupFailure))
        } else {
            transition(to: terminal ? .closed : .detached)
        }
    }

    private func commitDetachedReset(
        _ result: ReducerWorkResult,
        token: UInt64
    ) -> ReducerWork? {
        guard attachmentGeneration == token else {
            return nil
        }
        switch result.output {
        case let .reset(networkResult, consoleResult, pageHighlightDOM):
            return .acknowledgements(
                network: networkRequests.commit(networkResult),
                console: consoleMessages.commit(consoleResult),
                pageHighlightDOM: pageHighlightDOM
            )
        case .none, .network, .console, .pageHighlightClear, .inspectorSelection:
            preconditionFailure("A detached reset produced an invalid reducer result.")
        }
    }

    private static func makeCleanupTask(
        after predecessor: Task<Failure?, Never>?,
        attachmentTask: Task<Failure?, Never>?,
        driverTask: Task<Void, Never>?,
        feed: ConnectionModelFeed?,
        proxy: WebInspectorProxy?
    ) -> Task<Failure?, Never>? {
        guard predecessor != nil || attachmentTask != nil || driverTask != nil
                || feed != nil || proxy != nil else {
            return nil
        }
        return Task.detached(priority: .userInitiated) {
            var firstFailure = await predecessor?.value
            if let attachmentFailure = await attachmentTask?.value,
               firstFailure == nil {
                firstFailure = attachmentFailure
            }
            await driverTask?.value
            if let feed {
                do {
                    try await feed.close()
                } catch {
                    if firstFailure == nil {
                        firstFailure = mapAttachmentFailure(error)
                    }
                }
            }
            await proxy?.close()
            return firstFailure
        }
    }

    private func prepareSemanticReset(
    ) -> ReducerWork {
        domState.advanceDocumentEpoch()
        let pageHighlightDOM = resetDOM()
        runtimeState.reset()
        let consoleReset = consoleMessages.prepareClearForLifecycle(
            modelContext: self
        )
        applyConsoleMessageEffects(consoleReset.effects)
        let networkReset = networkRequests.prepareResetForNewAttachment()
        return .reset(
            network: networkRequests.indexWork(for: networkReset),
            console: consoleMessages.indexWork(for: consoleReset.queryIndexReset),
            pageHighlightDOM: pageHighlightDOM
        )
    }

    private func invalidateBindingState() {
        binding = nil
        pageGeneration = nil
        currentPage = nil
        pendingReducerCommitAction = .none
        ownsElementPickerLease = false
        isElementPickerTransitioning = false
    }

    fileprivate func prepareFailure(
        _ failure: Failure,
        token: UInt64
    ) -> PreparedReducerStep? {
        guard attachmentTransition?.token == token,
              !isTerminallyClosed,
              state != .detaching else {
            return nil
        }
        attachmentTask = nil
        driverTask = nil
        invalidateBindingState()
        pendingReducerCommitAction = .failure(failure)
        return PreparedReducerStep(
            work: prepareSemanticReset(),
            commit: .record(token: token)
        )
    }

    fileprivate func prepare(
        _ record: ConnectionModelFeedRecord,
        token: UInt64
    ) -> PreparedReducerStep? {
        guard attachmentTransition?.token == token,
              !isTerminallyClosed else {
            return nil
        }
        pendingReducerCommitAction = .none

        switch record {
        case let .reset(generation):
            if let binding,
               generation.rawValue <= binding.generation.rawValue {
                return prepareProtocolFailure(
                    "Model feed reset generations must increase.",
                    token: token
                )
            }
            let work: ReducerWork
            if binding == nil && didPrepareAttachmentReset {
                work = .none
            } else {
                work = prepareSemanticReset()
            }
            currentPage = nil
            self.binding = BindingState(
                generation: generation,
                lastSequence: nil,
                targetSnapshotWasApplied: false,
                currentPageID: nil,
                targets: [:],
                navigationEpochs: [:],
                domAuthority: [:],
                runtimeBindingEpochs: [:],
                consoleBindingEpochs: [:],
                bootstrapSnapshotThrough: [:],
                bootstrapCompletionThrough: [:],
                completedDomains: [],
                didSynchronize: false
            )
            pageGeneration = PageGeneration(generation)
            if didCompleteInitialAttachment {
                readinessCompletion?.fulfill(.failure(TransitionError.superseded))
                readinessCompletion = ReplyPromise<Void>()
            }
            transition(to: .synchronizing(PageGeneration(generation)))
            return PreparedReducerStep(work: work, commit: .record(token: token))

        case let .targetSnapshot(generation, through, snapshot):
            guard var binding = bindingForRecord(generation),
                  !binding.targetSnapshotWasApplied,
                  snapshot.targets.contains(where: {
                      $0.target.id == snapshot.currentPageID
                  }),
                  Set(snapshot.targets.map(\.target.id)).count
                    == snapshot.targets.count,
                  snapshot.targets.allSatisfy({ state in
                      let hasValidDOMEpoch = configuredDomains.contains(.dom)
                        ? state.domBindingEpoch != nil
                        : state.domBindingEpoch == nil
                      let hasValidRuntimeEpoch = requiresRuntimeBinding
                        ? state.runtimeBindingEpoch != nil
                        : state.runtimeBindingEpoch == nil
                      let hasValidConsoleEpoch = configuredDomains.contains(.console)
                        ? state.consoleBindingEpoch != nil
                        : state.consoleBindingEpoch == nil
                      return hasValidDOMEpoch
                        && hasValidRuntimeEpoch
                        && hasValidConsoleEpoch
                  }) else {
                return prepareProtocolFailure(
                    "Model target snapshot was stale, duplicated, or missing its current page.",
                    token: token
                )
            }
            guard acceptWatermark(through, in: &binding) else {
                return prepareProtocolFailure(
                    "Model target snapshot moved the feed watermark backwards.",
                    token: token
                )
            }
            binding.targetSnapshotWasApplied = true
            binding.currentPageID = snapshot.currentPageID
            binding.targets = Dictionary(
                uniqueKeysWithValues: snapshot.targets.map {
                    ($0.target.id, $0.target)
                }
            )
            binding.navigationEpochs = Dictionary(
                uniqueKeysWithValues: snapshot.targets.map {
                    ($0.target.id, $0.navigationEpoch)
                }
            )
            if configuredDomains.contains(.dom) {
                binding.domAuthority = Dictionary(
                    uniqueKeysWithValues: snapshot.targets.map { state in
                        guard let epoch = state.domBindingEpoch else {
                            preconditionFailure(
                                "A validated DOM target state lost its binding epoch."
                            )
                        }
                        return (state.target.id, .awaiting(epoch))
                    }
                )
            }
            if requiresRuntimeBinding {
                binding.runtimeBindingEpochs = Dictionary(
                    uniqueKeysWithValues: snapshot.targets.map { state in
                        guard let epoch = state.runtimeBindingEpoch else {
                            preconditionFailure(
                                "A validated Runtime target state lost its binding epoch."
                            )
                        }
                        return (state.target.id, epoch)
                    }
                )
            }
            if configuredDomains.contains(.console) {
                binding.consoleBindingEpochs = Dictionary(
                    uniqueKeysWithValues: snapshot.targets.map { state in
                        guard let epoch = state.consoleBindingEpoch else {
                            preconditionFailure(
                                "A validated Console target state lost its binding epoch."
                            )
                        }
                        return (state.target.id, epoch)
                    }
                )
            }
            self.binding = binding
            guard let pageTarget = binding.targets[snapshot.currentPageID],
                  let target = authorizedTarget(pageTarget, documentEpoch: nil) else {
                return prepareProtocolFailure(
                    "Model target snapshot could not construct current-page authority.",
                    token: token
                )
            }
            currentPage = target
            return PreparedReducerStep(work: .none, commit: .record(token: token))

        case let .domDocumentInvalidated(sequence, scope):
            let target = scope.target
            guard var binding = bindingForSequencedRecord(
                scope.generation,
                sequence: sequence
            ),
                  configuredDomains.contains(.dom),
                  binding.targets[target.id] == target,
                  binding.navigationEpochs[target.id] == scope.navigationEpoch,
                  let documentEpoch = scope.domBindingEpoch,
                  let previousAuthority = binding.domAuthority[target.id],
                  documentEpoch.rawValue == previousAuthority.epoch.rawValue + 1 else {
                return prepareProtocolFailure(
                    "DOM document invalidation did not advance the registered target epoch exactly once.",
                    token: token
                )
            }
            binding.domAuthority[target.id] = .awaiting(documentEpoch)
            self.binding = binding
            let work: ReducerWork
            if target.id == binding.currentPageID {
                domState.advanceDocumentEpoch()
                if let pageHighlightDOM = resetDOM() {
                    work = .preparePageHighlightClear(pageHighlightDOM)
                } else {
                    work = .none
                }
            } else if let frameID = target.frameID {
                cssInspectorBaselineStore.reset(targetID: target.id)
                applyDOMStateEffects(
                    domState.detachProjectedFrameDocument(
                        forFrameID: frameID
                    )
                )
                work = .none
            } else {
                return prepareProtocolFailure(
                    "A non-page DOM target had no frame identity.",
                    token: token
                )
            }
            return PreparedReducerStep(work: work, commit: .record(token: token))

        case let .event(sequence, scope, payload):
            guard var binding = bindingForSequencedRecord(
                scope.generation,
                sequence: sequence
            ), binding.targetSnapshotWasApplied else {
                return prepareProtocolFailure(
                    "A model event arrived outside an authoritative target snapshot.",
                    token: token
                )
            }
            self.binding = binding
            let work = prepare(
                payload,
                scope: scope,
                binding: &binding,
                token: token
            )
            guard let work else {
                return nil
            }
            if case .failure = pendingReducerCommitAction {
                // `prepareProtocolFailure` already invalidated the binding.
            } else {
                self.binding = binding
                guard refreshCurrentPageAuthorization() else {
                    return prepareProtocolFailure(
                        "A model event left the current-page command authority incomplete.",
                        token: token
                    )
                }
            }
            return PreparedReducerStep(work: work, commit: .record(token: token))

        case let .replayComplete(generation, domain, through):
            guard var binding = bindingForRecord(generation),
                  binding.targetSnapshotWasApplied,
                  domain != .dom,
                  configuredModelDomains.contains(domain),
                  !binding.completedDomains.contains(domain),
                  acceptWatermark(through, in: &binding) else {
                return prepareProtocolFailure(
                    "A replay completion marker was stale, duplicated, or unconfigured.",
                    token: token
                )
            }
            binding.completedDomains.insert(domain)
            self.binding = binding
            return PreparedReducerStep(work: .none, commit: .record(token: token))

        case let .bootstrapSnapshot(generation, domain, sequence, payload):
            switch (domain, payload) {
            case let (.dom, .domDocument(scope, root)):
                let target = scope.target
                guard configuredDomains.contains(.dom),
                      scope.generation == generation,
                      let documentEpoch = scope.domBindingEpoch,
                      var binding = bindingForWatermarkedRecord(
                          generation,
                          sequence: sequence
                      ),
                      binding.bootstrapSnapshotThrough[.dom].map({
                          sequence > $0
                      }) ?? true else {
                    return prepareProtocolFailure(
                        "A DOM bootstrap snapshot was stale or unconfigured.",
                        token: token
                    )
                }
                guard binding.targets[target.id] == target,
                      binding.navigationEpochs[target.id]
                        == scope.navigationEpoch,
                      case let .awaiting(expectedEpoch)? = binding.domAuthority[target.id],
                      expectedEpoch == documentEpoch else {
                    return prepareProtocolFailure(
                        "A DOM bootstrap snapshot did not match its target epoch.",
                        token: token
                    )
                }
                let effects: DOMStateStore.Effects?
                if target.id == binding.currentPageID {
                    effects = domState.applyDocument(
                        root,
                        expectedEpoch: domState.documentEpoch,
                        reason: didCompleteInitialAttachment ? .pageChanged : .initialDocument,
                        modelContext: self
                    )
                } else {
                    effects = domState.applyFrameDocument(
                        root,
                        frameTargetID: target.id,
                        expectedEpoch: domState.documentEpoch,
                        modelContext: self
                    )
                }
                guard let effects else {
                    return prepareProtocolFailure(
                        "A DOM bootstrap snapshot lost its local document epoch.",
                        token: token
                    )
                }
                applyDOMStateEffects(effects)
                binding.domAuthority[target.id] = .ready(documentEpoch)
                binding.bootstrapSnapshotThrough[.dom] = sequence
                self.binding = binding
                return PreparedReducerStep(work: .none, commit: .record(token: token))

            case let (.css, .cssStyleSheets(styleSheets)):
                guard configuredModelDomains.contains(.css),
                      var binding = bindingForWatermarkedRecord(
                          generation,
                          sequence: sequence
                      ),
                      binding.bootstrapSnapshotThrough[.css].map({
                          sequence > $0
                      }) ?? true,
                      styleSheets.allSatisfy({ styleSheet in
                          let scope = styleSheet.scope
                          return scope.generation == generation
                            && binding.targets[scope.target.id]
                                == scope.target
                            && binding.navigationEpochs[scope.target.id]
                                == scope.navigationEpoch
                            && scope.domBindingEpoch
                                == binding.domAuthority[scope.target.id]?.epoch
                      }) else {
                    return prepareProtocolFailure(
                        "A CSS bootstrap snapshot was stale, duplicated, or unconfigured.",
                        token: token
                    )
                }
                binding.bootstrapSnapshotThrough[.css] = sequence
                domState.markAllStylesNeedsRefresh()
                self.binding = binding
                return PreparedReducerStep(work: .none, commit: .record(token: token))

            case (.dom, .cssStyleSheets), (.css, .domDocument),
                 (.network, _), (.console, _), (.runtime, _):
                return prepareProtocolFailure(
                    "A bootstrap snapshot payload did not match its domain.",
                    token: token
                )
            }

        case let .bootstrapComplete(generation, domain, through):
            guard var binding = bindingForRecord(generation),
                  acceptWatermark(through, in: &binding) else {
                return prepareProtocolFailure(
                    "A bootstrap completion marker was stale.",
                    token: token
                )
            }
            switch domain {
            case .dom:
                guard configuredDomains.contains(.dom),
                      binding.domAuthority.values.allSatisfy({ authority in
                          if case .ready = authority { return true }
                          return false
                      }) else {
                    return prepareProtocolFailure(
                        "A DOM bootstrap completed before every target snapshot was applied.",
                        token: token
                    )
                }
            case .css:
                guard configuredModelDomains.contains(.css),
                      binding.bootstrapSnapshotThrough[.css] != nil else {
                    return prepareProtocolFailure(
                        "A CSS bootstrap completed before its snapshot was applied.",
                        token: token
                    )
                }
            case .network, .console, .runtime:
                return prepareProtocolFailure(
                    "A replay-only domain published a bootstrap completion.",
                    token: token
                )
            }
            guard binding.bootstrapCompletionThrough[domain].map({
                through > $0
            }) ?? true else {
                return prepareProtocolFailure(
                    "A model bootstrap completion marker was duplicated.",
                    token: token
                )
            }
            binding.bootstrapCompletionThrough[domain] = through
            if !binding.didSynchronize {
                binding.completedDomains.insert(domain)
            }
            self.binding = binding
            return PreparedReducerStep(work: .none, commit: .record(token: token))

        case let .synchronizationComplete(generation, through):
            guard var binding = bindingForRecord(generation),
                  binding.targetSnapshotWasApplied,
                  !binding.didSynchronize,
                  binding.completedDomains == configuredModelDomains,
                  acceptWatermark(through, in: &binding) else {
                return prepareProtocolFailure(
                    "Binding synchronization completed before every configured domain.",
                    token: token
                )
            }
            self.binding = binding
            pendingReducerCommitAction = .synchronizationComplete(
                generation: generation,
                through: through
            )
            return PreparedReducerStep(work: .none, commit: .record(token: token))
        }
    }

    private func acceptAgentBindings(
        _ scope: ModelEventScope,
        in binding: inout BindingState,
        runtimeMayAdvance: Bool = false,
        runtimeMustAdvance: Bool = false,
        consoleMustAdvance: Bool = false
    ) -> Bool {
        let agentTarget = scope.agentTarget
        guard binding.targets[agentTarget.id] == agentTarget else {
            return false
        }

        if requiresRuntimeBinding {
            guard let previous = binding.runtimeBindingEpochs[agentTarget.id],
                  let epoch = scope.runtimeBindingEpoch else {
                return false
            }
            let didAdvance = previous.rawValue < UInt64.max
                && epoch.rawValue == previous.rawValue + 1
            if runtimeMustAdvance {
                guard didAdvance else { return false }
            } else if runtimeMayAdvance {
                guard epoch == previous || didAdvance else { return false }
            } else {
                guard epoch == previous else { return false }
            }
            binding.runtimeBindingEpochs[agentTarget.id] = epoch
        } else if scope.runtimeBindingEpoch != nil {
            return false
        }

        if configuredDomains.contains(.console) {
            guard let previous = binding.consoleBindingEpochs[agentTarget.id],
                  let epoch = scope.consoleBindingEpoch else {
                return false
            }
            if consoleMustAdvance {
                guard previous.rawValue < UInt64.max,
                      epoch.rawValue == previous.rawValue + 1 else {
                    return false
                }
            } else {
                guard epoch == previous else { return false }
            }
            binding.consoleBindingEpochs[agentTarget.id] = epoch
        } else if scope.consoleBindingEpoch != nil {
            return false
        }
        return true
    }

    private func installAgentBindings(
        _ scope: ModelEventScope,
        in binding: inout BindingState
    ) -> Bool {
        let agentTarget = scope.agentTarget
        guard agentTarget == scope.target,
              binding.runtimeBindingEpochs[agentTarget.id] == nil,
              binding.consoleBindingEpochs[agentTarget.id] == nil else {
            return false
        }
        if requiresRuntimeBinding {
            guard let epoch = scope.runtimeBindingEpoch else { return false }
            binding.runtimeBindingEpochs[agentTarget.id] = epoch
        } else if scope.runtimeBindingEpoch != nil {
            return false
        }
        if configuredDomains.contains(.console) {
            guard let epoch = scope.consoleBindingEpoch else { return false }
            binding.consoleBindingEpochs[agentTarget.id] = epoch
        } else if scope.consoleBindingEpoch != nil {
            return false
        }
        return true
    }

    private func prepare(
        _ payload: ModelProtocolEvent,
        scope: ModelEventScope,
        binding: inout BindingState,
        token: UInt64
    ) -> ReducerWork? {
        let target = scope.target
        let agentTarget = scope.agentTarget
        switch payload {
        case let .target(event):
            switch event {
            case .targetCreated:
                guard binding.targets[target.id] == nil,
                      binding.navigationEpochs[target.id] == nil,
                      installAgentBindings(scope, in: &binding),
                      configuredDomains.contains(.dom)
                        ? scope.domBindingEpoch != nil
                        : scope.domBindingEpoch == nil else {
                    return prepareProtocolFailure(
                        "A model target was created twice or with an invalid scope.",
                        token: token
                    )?.work
                }
                binding.targets[target.id] = target
                binding.navigationEpochs[target.id] = scope.navigationEpoch
                if configuredDomains.contains(.dom) {
                    guard let epoch = scope.domBindingEpoch else {
                        preconditionFailure(
                            "A validated DOM target creation lost its binding epoch."
                        )
                    }
                    binding.domAuthority[target.id] = .awaiting(epoch)
                }
            case .targetDestroyed:
                guard binding.targets[target.id] == target,
                      binding.navigationEpochs[target.id]
                        == scope.navigationEpoch,
                      acceptAgentBindings(scope, in: &binding),
                      scope.domBindingEpoch
                        == binding.domAuthority[target.id]?.epoch else {
                    return prepareProtocolFailure(
                        "A model target was destroyed without matching scope membership.",
                        token: token
                    )?.work
                }
                binding.targets.removeValue(forKey: target.id)
                binding.navigationEpochs.removeValue(forKey: target.id)
                binding.domAuthority.removeValue(forKey: target.id)
                binding.runtimeBindingEpochs.removeValue(forKey: target.id)
                binding.consoleBindingEpochs.removeValue(forKey: target.id)
                cssInspectorBaselineStore.reset(targetID: target.id)
                if let frameID = target.frameID {
                    applyDOMStateEffects(
                        domState.detachProjectedFrameDocument(
                            forFrameID: frameID
                        )
                    )
                }
            case let .didCommitProvisionalTarget(oldTargetID):
                binding.targets.removeValue(forKey: oldTargetID)
                binding.navigationEpochs.removeValue(forKey: oldTargetID)
                binding.domAuthority.removeValue(forKey: oldTargetID)
                binding.runtimeBindingEpochs.removeValue(forKey: oldTargetID)
                binding.consoleBindingEpochs.removeValue(forKey: oldTargetID)
                cssInspectorBaselineStore.reset(targetID: oldTargetID)
                guard binding.targets[target.id] == nil,
                      installAgentBindings(scope, in: &binding),
                      configuredDomains.contains(.dom)
                        ? scope.domBindingEpoch != nil
                        : scope.domBindingEpoch == nil else {
                    return prepareProtocolFailure(
                        "A committed model target conflicted with existing scope membership.",
                        token: token
                    )?.work
                }
                binding.targets[target.id] = target
                binding.navigationEpochs[target.id] = scope.navigationEpoch
                if configuredDomains.contains(.dom) {
                    guard let epoch = scope.domBindingEpoch else {
                        preconditionFailure(
                            "A validated committed DOM target lost its binding epoch."
                        )
                    }
                    binding.domAuthority[target.id] = .awaiting(epoch)
                }
            case .frameNavigated:
                guard binding.targets[target.id] == target,
                      acceptAgentBindings(
                          scope,
                          in: &binding,
                          runtimeMayAdvance: true
                      ),
                      let previousEpoch = binding.navigationEpochs[target.id],
                      scope.domBindingEpoch
                        == binding.domAuthority[target.id]?.epoch,
                      scope.navigationEpoch.rawValue == previousEpoch.rawValue
                        || scope.navigationEpoch.rawValue
                            == previousEpoch.rawValue + 1 else {
                    return prepareProtocolFailure(
                        "A frame navigation did not preserve or advance its registered scope exactly once.",
                        token: token
                    )?.work
                }
                binding.navigationEpochs[target.id] = scope.navigationEpoch
            case let .frameDetached(frameID):
                guard binding.targets[target.id] == target,
                      acceptAgentBindings(scope, in: &binding),
                      binding.navigationEpochs[target.id]
                        == scope.navigationEpoch,
                      scope.domBindingEpoch
                        == binding.domAuthority[target.id]?.epoch else {
                    return prepareProtocolFailure(
                        "A frame detach referenced a foreign navigation scope.",
                        token: token
                    )?.work
                }
                applyDOMStateEffects(
                    domState.detachProjectedFrameDocument(
                        forFrameID: frameID
                    )
                )
            }
            return ReducerWork.none

        case let .dom(event):
            guard configuredDomains.contains(.dom),
                  acceptAgentBindings(scope, in: &binding),
                  binding.targets[target.id] == target,
                  binding.navigationEpochs[target.id] == scope.navigationEpoch,
                  scope.domBindingEpoch == binding.domAuthority[target.id]?.epoch,
                  let authority = binding.domAuthority[target.id] else {
                return prepareProtocolFailure(
                    "A DOM event referenced an unconfigured or foreign target.",
                    token: token
                )?.work
            }
            guard case .ready = authority else {
                return prepareProtocolFailure(
                    "A DOM event arrived before its authoritative target bootstrap.",
                    token: token
                )?.work
            }
            if case .documentUpdated = event {
                return prepareProtocolFailure(
                    "DOM.documentUpdated bypassed its authoritative invalidation record.",
                    token: token
                )?.work
            }
            applyDOMStateEffects(
                domState.apply(event, modelContext: self)
            )
            return ReducerWork.none

        case let .inspector(event):
            guard ownsElementPickerLease else {
                return ReducerWork.none
            }
            guard configuredDomains.contains(.dom),
                  acceptAgentBindings(scope, in: &binding),
                  binding.targets[target.id] == target,
                  binding.navigationEpochs[target.id] == scope.navigationEpoch,
                  scope.domBindingEpoch == binding.domAuthority[target.id]?.epoch,
                  target.id == binding.currentPageID,
                  case let .ready(documentEpoch)? = binding.domAuthority[target.id],
                  let authorizedTarget = authorizedTarget(
                      target,
                      documentEpoch: documentEpoch
                  ),
                  let activeFeed else {
                return prepareProtocolFailure(
                    "An Inspector event referenced an unauthorized document target.",
                    token: token
                )?.work
            }
            guard case let .inspect(object, _) = event else {
                return ReducerWork.none
            }
            let objectID: Runtime.RemoteObject.ID? = if object.subtype?.rawValue == "node" {
                object.id
            } else {
                nil
            }
            return .inspectorSelection(
                dom: authorizedTarget.dom,
                objectID: objectID,
                feed: activeFeed,
                expectedSelectionRevision: domState.selectionRevision
            )

        case let .css(event):
            guard configuredDomains.contains(.css),
                  acceptAgentBindings(scope, in: &binding),
                  binding.targets[target.id] == target,
                  binding.navigationEpochs[target.id] == scope.navigationEpoch,
                  scope.domBindingEpoch == binding.domAuthority[target.id]?.epoch,
                  binding.domAuthority[target.id] != nil else {
                return prepareProtocolFailure(
                    "A CSS event referenced an unconfigured or foreign target.",
                    token: token
                )?.work
            }
            apply(event)
            return ReducerWork.none

        case let .network(event):
            guard configuredDomains.contains(.network),
                  acceptAgentBindings(scope, in: &binding),
                  binding.targets[target.id] == target,
                  binding.navigationEpochs[target.id] == scope.navigationEpoch,
                  scope.domBindingEpoch
                    == binding.domAuthority[target.id]?.epoch else {
                return prepareProtocolFailure(
                    "A Network event referenced an unconfigured or foreign target.",
                    token: token
                )?.work
            }
            return networkRequests.prepareModelEvent(
                event,
                modelContext: self
            ).map(ReducerWork.network) ?? ReducerWork.none

        case let .console(event):
            let clearsMessages: Bool
            if case .messagesCleared = event {
                clearsMessages = true
            } else {
                clearsMessages = false
            }
            guard configuredDomains.contains(.console),
                  acceptAgentBindings(
                      scope,
                      in: &binding,
                      consoleMustAdvance: clearsMessages
                  ),
                  binding.targets[target.id] == target,
                  binding.navigationEpochs[target.id] == scope.navigationEpoch,
                  scope.domBindingEpoch
                    == binding.domAuthority[target.id]?.epoch else {
                return prepareProtocolFailure(
                    "A Console event referenced an unconfigured or foreign target.",
                    token: token
                )?.work
            }
            let prepared = consoleMessages.prepareModelEvent(
                event,
                targetID: target.id,
                modelContext: self,
                registerRuntimeObject: { payload in
                    runtimeState.registerConsoleParameter(
                        payload
                    )
                }
            )
            applyConsoleMessageEffects(prepared.effects)
            return prepared.indexWork.map(ReducerWork.console) ?? ReducerWork.none

        case let .runtime(event):
            let clearsExecutionContexts: Bool
            if case .executionContextsCleared = event {
                clearsExecutionContexts = true
            } else {
                clearsExecutionContexts = false
            }
            let isOperationalConsoleInvalidation = clearsExecutionContexts
                && configuredDomains.contains(.console)
            guard configuredDomains.contains(.runtime)
                    || isOperationalConsoleInvalidation,
                  acceptAgentBindings(
                      scope,
                      in: &binding,
                      runtimeMustAdvance: clearsExecutionContexts
                  ),
                  binding.targets[target.id] == target,
                  binding.navigationEpochs[target.id] == scope.navigationEpoch,
                  scope.domBindingEpoch
                    == binding.domAuthority[target.id]?.epoch else {
                return prepareProtocolFailure(
                    "A Runtime event referenced an unconfigured or foreign target.",
                    token: token
                )?.work
            }
            runtimeState.apply(
                event,
                sourceTargetID: agentTarget.id,
                isCurrentPageTarget: agentTarget.id == binding.currentPageID
            )
            return ReducerWork.none
        }
    }

    private func finishPreparedRecord() {
        let action = pendingReducerCommitAction
        pendingReducerCommitAction = .none
        switch action {
        case .none:
            break
        case let .failure(failure):
            guard let token = attachmentTransition?.token else {
                return
            }
            transitionToFailure(failure, token: token)
        case let .synchronizationComplete(generation, through):
            guard var binding,
                  binding.generation == generation,
                  binding.lastSequence.map({ through >= $0 }) ?? true,
                  !binding.didSynchronize else {
                preconditionFailure(
                    "A prepared model synchronization lost its reducer state."
                )
            }
            binding.didSynchronize = true
            self.binding = binding
            didCompleteInitialAttachment = true
            if ownsElementPickerLease {
                applyDOMStateEffects(
                    domState.setElementPickerEnabled(true)
                )
            }
            transition(to: .attached)
            attachmentTransition?.completion.fulfill(.success(()))
            readinessCompletion?.fulfill(.success(()))
            readinessCompletion = nil
        }
    }

    private func prepareProtocolFailure(
        _ message: String,
        token: UInt64
    ) -> PreparedReducerStep? {
        prepareFailure(
            .connection(.protocolViolation(message)),
            token: token
        )
    }

    private func bindingForRecord(
        _ generation: WebInspectorPage.Generation
    ) -> BindingState? {
        guard let binding, binding.generation == generation else {
            return nil
        }
        return binding
    }

    private func bindingForSequencedRecord(
        _ generation: WebInspectorPage.Generation,
        sequence: UInt64
    ) -> BindingState? {
        guard var binding = bindingForRecord(generation),
              binding.lastSequence.map({ sequence > $0 }) ?? true else {
            return nil
        }
        binding.lastSequence = sequence
        return binding
    }

    private func bindingForWatermarkedRecord(
        _ generation: WebInspectorPage.Generation,
        sequence: UInt64
    ) -> BindingState? {
        guard var binding = bindingForRecord(generation),
              acceptWatermark(sequence, in: &binding) else {
            return nil
        }
        return binding
    }

    private func acceptWatermark(
        _ sequence: UInt64,
        in binding: inout BindingState
    ) -> Bool {
        guard binding.lastSequence.map({ sequence >= $0 }) ?? true else {
            return false
        }
        binding.lastSequence = sequence
        return true
    }

    private func authorizedTarget(
        _ target: ModelTarget,
        documentEpoch: ModelDOMBindingEpoch?
    ) -> WebInspectorTarget? {
        guard let activeProxy, let activeFeed, let binding else {
            return nil
        }
        let document = documentEpoch.map {
            ConnectionModelCommandAuthorization.Document(
                targetID: target.id,
                epoch: $0
            )
        }
        let runtime = binding.runtimeBindingEpochs[target.id].map { epoch in
            ConnectionModelCommandAuthorization.Runtime(
                agentTargetID: target.id,
                epoch: epoch,
                semanticTarget: binding.navigationEpochs[target.id].map {
                    ConnectionModelCommandAuthorization.Runtime.SemanticTarget(
                        targetID: target.id,
                        navigationEpoch: $0
                    )
                }
            )
        }
        return activeProxy.modelTarget(
            target,
            authorization: ConnectionModelCommandAuthorization(
                feedID: activeFeed.id,
                generation: binding.generation,
                document: document,
                runtime: runtime
            )
        )
    }

    private func refreshCurrentPageAuthorization() -> Bool {
        guard let binding,
              let currentPageID = binding.currentPageID,
              let target = binding.targets[currentPageID],
              let authorized = authorizedTarget(target, documentEpoch: nil) else {
            return false
        }
        currentPage = authorized
        return true
    }

    private func advanceAttachmentToken() -> UInt64 {
        precondition(
            attachmentGeneration < UInt64.max,
            "WebInspectorModelContext exhausted its attachment generation."
        )
        attachmentGeneration += 1
        return attachmentGeneration
    }

    private var configuredModelDomains: Set<ModelDomain> {
        Set(configuredDomains.map(Self.modelDomain))
    }

    private var requiresRuntimeBinding: Bool {
        configuredDomains.contains(.runtime)
            || configuredDomains.contains(.console)
    }

    private static func modelDomain(_ domain: Domain) -> ModelDomain {
        switch domain.rawValue {
        case Domain.dom.rawValue:
            .dom
        case Domain.network.rawValue:
            .network
        case Domain.console.rawValue:
            .console
        case Domain.runtime.rawValue:
            .runtime
        case Domain.css.rawValue:
            .css
        default:
            preconditionFailure("A closed model domain had an unknown value.")
        }
    }

    private static func domain(_ domain: ModelDomain) -> Domain {
        switch domain {
        case .dom:
            .dom
        case .network:
            .network
        case .console:
            .console
        case .runtime:
            .runtime
        case .css:
            .css
        }
    }

    private static func mapAttachmentFailure(_ error: any Error) -> Failure {
        if let scopeError = error as? WebInspectorScopeError {
            return .connection(.transport(
                "Operation failed: \(String(describing: scopeError.operationError)); cleanup failed: \(String(describing: scopeError.cleanupError))"
            ))
        }
        if let feedError = error as? ConnectionModelFeedError {
            switch feedError {
            case let .bootstrapFailed(domain, message):
                return .bootstrap(domain: Self.domain(domain), message: message)
            case .connectionAlreadyUsedByDirectConsumer:
                return .connection(.protocolViolation(
                    "The Proxy connection was already used outside its model feed."
                ))
            case .alreadyOpen:
                return .connection(.protocolViolation(
                    "The Proxy connection already owns a model feed."
                ))
            case .consumerTerminated:
                return .connection(.transport("The model feed consumer terminated."))
            }
        }
        if let proxyError = error as? WebInspectorProxyError {
            switch proxyError {
            case .closed:
                return .connection(.closed)
            case .pageUnavailable:
                return .connection(.pageUnavailable)
            case let .protocolViolation(message):
                return .connection(.protocolViolation(message))
            case let .transportFailure(message), let .disconnected(message),
                 let .attachFailed(message):
                return .connection(.transport(message))
            case let .unsupported(features):
                return .connection(.transport(features.joined(separator: ", ")))
            case let .commandRejected(method, message):
                return .connection(.transport("\(method): \(message)"))
            case let .commandFailed(domain, method, message):
                return .connection(.transport("\(domain).\(method): \(message)"))
            case .staleIdentifier:
                return .connection(.protocolViolation("Attachment became stale during startup."))
            case let .eventBufferOverflow(capacity):
                return .connection(.transport(
                    "An auxiliary event subscriber exceeded its buffer capacity of \(capacity)."
                ))
            case .connectionInUse:
                return .connection(.protocolViolation("The Proxy connection is already in use."))
            case let .timeout(domain, method):
                return .connection(.transport("Timed out waiting for \(domain).\(method)."))
            }
        }
        return .connection(.transport(String(describing: error)))
    }

    private static func isPickerSupersession(
        _ error: any Error
    ) -> Bool {
        guard let proxyError = error as? WebInspectorProxyError else {
            return false
        }
        switch proxyError {
        case .staleIdentifier, .pageUnavailable:
            return true
        case .unsupported, .attachFailed, .closed, .disconnected,
             .commandFailed, .protocolViolation, .eventBufferOverflow,
             .connectionInUse, .commandRejected, .transportFailure,
             .timeout:
            return false
        }
    }

    /// Returns the current DOM identity for an identifier.
    public func domNode(id: DOMNode.ID) throws -> DOMNode? {
        try requireConfigured(.dom)
        return domState.node(for: id)
    }

    package func requiredNode(for id: DOMNode.ID) throws -> DOMNode {
        return try domState.requiredNode(for: id)
    }

    /// Returns the current Network identity for an identifier.
    public func networkRequest(id: NetworkRequest.ID) throws -> NetworkRequest? {
        try requireConfigured(.network)
        return networkRequests.request(for: id)
    }

    package var networkRequestsCollectionState: NetworkRequestCollectionState {
        networkRequests.collectionState
    }

    package func networkRequestGroupID(
        containing requestID: NetworkRequest.ID
    ) -> WebInspectorFetchSectionID? {
        networkRequests.groupID(containing: requestID)
    }

    package func networkRequestIDs(
        inGroup groupID: WebInspectorFetchSectionID
    ) -> [NetworkRequest.ID]? {
        networkRequests.requestIDs(inGroup: groupID)
    }

    package func networkRequestGroup(
        id groupID: WebInspectorFetchSectionID
    ) -> WebInspectorFetchSection<NetworkRequest>? {
        networkRequests.requestGroup(id: groupID)
    }

    package func registeredRequest(
        forProxyID id: Network.Request.ID
    ) -> NetworkRequest? {
        return networkRequests.request(forProxyID: id)
    }

    /// Clears canonical Network membership for every context of this model
    /// container and waits until all contexts at the commit boundary apply it.
    public nonisolated(nonsending) func clearNetworkRequests() async throws {
        preconditionOwnerIsolation()
        guard configuredDomains.contains(.network) else {
            return
        }
        guard let binding = containerRegistrationBinding else {
            throw WebInspectorModelError.staleModel
        }
        try await binding.core.clearNetworkRequests()
    }

    /// Returns the registered Console message for an identifier.
    package func registeredMessage(
        for id: ConsoleMessage.ID
    ) -> ConsoleMessage? {
        return consoleMessages.message(for: id)
    }

    /// Selects a DOM node and publishes the requested tree reveal intent.
    public func selectDOMNode(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy = .selectAndScroll
    ) throws {
        try requireConfigured(.dom)
        if let node {
            try registeredNode(node)
        }
        select(node, reveal: reveal)
    }

    private func select(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy
    ) {
        let effects = domState.select(node, reveal: reveal)
        applyDOMStateEffects(effects)
    }

    package func selectNode(_ id: DOMNode.ID) throws {
        select(try requiredNode(for: id), reveal: .selectAndScroll)
    }

    package func selectNode(
        _ id: DOMNode.ID?,
        reveal: DOMRevealPolicy
    ) throws {
        guard let id else {
            select(nil, reveal: reveal)
            return
        }
        select(try requiredNode(for: id), reveal: reveal)
    }

    package func requestChildren(
        for id: DOMNode.ID,
        depth: Int = 1
    ) async throws {
        try await requestDOMChildren(of: requiredNode(for: id), depth: depth)
    }

    /// Requests child nodes without moving DOM selection.
    public nonisolated(nonsending) func requestDOMChildren(
        of node: DOMNode,
        depth: Int = 1
    ) async throws {
        precondition(depth >= 0, "DOM child request depth must be non-negative.")
        try requireConfigured(.dom)
        try registeredNode(node)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.requestChildNodes(node.id.proxyID, depth: depth)
    }

    /// Sets one DOM attribute and returns its document-bound undo capability.
    public nonisolated(nonsending) func setDOMAttribute(
        _ name: String,
        value: String,
        on node: DOMNode,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        try requireConfigured(.dom)
        try registeredNode(node)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setAttributeValue(
            node.id.proxyID,
            name: name,
            value: value
        )
        let options = DOMMutationPolicy(undo: undo)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        return DOMMutationOutcome(
            requestedNodeIDs: [node.id],
            appliedNodeIDs: [node.id],
            failures: [],
            undo: makeDOMUndoCapability(policy: undo)
        )
    }

    /// Replaces one node's outer HTML and returns its undo capability.
    public nonisolated(nonsending) func setOuterHTML(
        _ html: String,
        of node: DOMNode,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        try requireConfigured(.dom)
        try registeredNode(node)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setOuterHTML(node.id.proxyID, html: html)
        let options = DOMMutationPolicy(undo: undo)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        return DOMMutationOutcome(
            requestedNodeIDs: [node.id],
            appliedNodeIDs: [node.id],
            failures: [],
            undo: makeDOMUndoCapability(policy: undo)
        )
    }

    /// Removes the current subset of nodes and reports every node-specific failure.
    public nonisolated(nonsending) func removeDOMNodes(
        _ nodes: [DOMNode],
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        try requireConfigured(.dom)
        let deletion = try domState.sortedDeletionNodes(for: nodes)
        let targets = try validatedDeletionTargets(for: deletion.nodes)
        let options = DOMMutationPolicy(undo: undo)
        var appliedNodeIDs: [DOMNode.ID] = []
        var failures: [DOMMutationFailure] = []
        for (node, target) in zip(deletion.nodes, targets) {
            do {
                try await target.dom.removeNode(node.id.proxyID)
                recordDOMEditHistoryTarget(target, options: options)
                try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
                appliedNodeIDs.append(node.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(DOMMutationFailure(
                    nodeID: node.id,
                    message: String(describing: error)
                ))
            }
        }
        applyDOMStateEffects(
            domState.clearSelectionIfDeleted(
                appliedNodeIDs,
                snapshot: deletion.snapshot
            )
        )
        return DOMMutationOutcome(
            requestedNodeIDs: nodes.map(\.id),
            appliedNodeIDs: appliedNodeIDs,
            failures: failures,
            undo: appliedNodeIDs.isEmpty ? nil : makeDOMUndoCapability(policy: undo)
        )
    }

    private func makeDOMUndoCapability(
        policy: WebInspectorUndoPolicy
    ) -> DOMUndoCapability? {
        guard policy == .automatic else {
            return nil
        }
        return DOMUndoCapability(commands: domUndoRedoCommands())
    }

    package func setDOMAttribute(
        _ name: String,
        value: String,
        on id: DOMNode.ID,
        options: DOMMutationPolicy
    ) async throws {
        let node = try requiredNode(for: id)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setAttributeValue(node.id.proxyID, name: name, value: value)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
    }

    package func setDOMOuterHTML(
        _ html: String,
        of id: DOMNode.ID,
        options: DOMMutationPolicy
    ) async throws {
        let node = try requiredNode(for: id)
        let target = try domTarget(owning: node.id.proxyID)
        try await target.dom.setOuterHTML(node.id.proxyID, html: html)
        recordDOMEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
    }

    package func removeDOMNodes(
        _ nodeIDs: [DOMNode.ID],
        options: DOMMutationPolicy
    ) async throws -> DOMMutationOutcome {
        let deletion = try domState.sortedDeletionNodes(for: nodeIDs)
        let sortedNodes = deletion.nodes
        let deletionTargets = try validatedDeletionTargets(for: sortedNodes)
        var acceptedNodeIDs: [DOMNode.ID] = []
        for (node, target) in zip(sortedNodes, deletionTargets) {
            do {
                try await target.dom.removeNode(node.id.proxyID)
                recordDOMEditHistoryTarget(target, options: options)
                try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
                acceptedNodeIDs.append(node.id)
            } catch {
                if acceptedNodeIDs.isEmpty == false {
                    applyDOMStateEffects(
                        domState.clearSelectionIfDeleted(
                            acceptedNodeIDs,
                            snapshot: deletion.snapshot
                        )
                    )
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: acceptedNodeIDs.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        applyDOMStateEffects(
            domState.clearSelectionIfDeleted(
                acceptedNodeIDs,
                snapshot: deletion.snapshot
            )
        )
        let undo = acceptedNodeIDs.isEmpty
            ? nil
            : DOMUndoCapability(commands: domUndoRedoCommands())
        return DOMMutationOutcome(
            requestedNodeIDs: nodeIDs,
            appliedNodeIDs: acceptedNodeIDs,
            failures: [],
            undo: undo
        )
    }

    /// Returns copied text for a DOM node in the requested format.
    public nonisolated(nonsending) func copyText(
        _ kind: DOMNode.CopyTextKind,
        for node: DOMNode
    ) async throws -> String {
        try requireConfigured(.dom)
        try registeredNode(node)
        switch kind {
        case .html:
            let target = try domTarget(owning: node.id.proxyID)
            return try await target.dom.outerHTML(of: node.id.proxyID)
        case .selectorPath:
            return try domState.currentTreeSnapshot(
                containing: [node]
            ).selectorPath(for: node.id)
        case .xPath:
            return try domState.currentTreeSnapshot(
                containing: [node]
            ).xPath(for: node.id)
        }
    }

    package func copyText(
        _ kind: DOMNode.CopyTextKind,
        for id: DOMNode.ID
    ) async throws -> String {
        try await copyText(kind, for: try requiredNode(for: id))
    }

    @discardableResult
    private func deleteCountingRemovedNodes(
        _ nodes: [DOMNode]
    ) async throws -> Int {
        let deletion = try domState.sortedDeletionNodes(for: nodes)
        let sortedNodes = deletion.nodes
        let deletionTargets = try validatedDeletionTargets(for: sortedNodes)
        var removedNodes: [DOMNode] = []
        for (node, target) in zip(sortedNodes, deletionTargets) {
            do {
                try await target.dom.removeNode(node.id.proxyID)
                recordDOMEditHistoryTarget(target, options: .init())
                try await target.dom.markUndoableState()
                removedNodes.append(node)
            } catch {
                if removedNodes.isEmpty == false {
                    applyDOMStateEffects(
                        domState.clearSelectionIfDeleted(
                            removedNodes.map(\.id),
                            snapshot: deletion.snapshot
                        )
                    )
                    throw DOMDeletionPartialFailure(
                        deletedNodeCount: removedNodes.count,
                        underlyingError: error
                    )
                }
                throw error
            }
        }
        applyDOMStateEffects(
            domState.clearSelectionIfDeleted(
                removedNodes.map(\.id),
                snapshot: deletion.snapshot
            )
        )
        return removedNodes.count
    }

    package func delete(nodeIDs: [DOMNode.ID]) async throws {
        _ = try await deleteCountingRemovedNodes(nodeIDs: nodeIDs)
    }

    @discardableResult
    package func deleteCountingRemovedNodes(
        nodeIDs: [DOMNode.ID]
    ) async throws -> Int {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let nodes = try nodeIDs
            .filter { seenNodeIDs.insert($0).inserted }
            .map { try domState.requiredNode(for: $0) }
        return try await deleteCountingRemovedNodes(nodes)
    }

    /// Highlights a DOM node in the inspected page.
    public nonisolated(nonsending) func highlightDOMNode(_ node: DOMNode) async throws {
        try requireConfigured(.dom)
        try registeredNode(node)
        let target = try domTarget(owning: node.id.proxyID)
        if node.id.proxyID.targetScopeRawValue == nil {
            domState.recordPageHighlight()
        }
        try await target.dom.highlightNode(node.id.proxyID)
    }

    package func highlightNode(for id: DOMNode.ID) async throws {
        try await highlightDOMNode(try requiredNode(for: id))
    }

    /// Clears the current DOM highlight in the inspected page.
    public nonisolated(nonsending) func hideDOMHighlight() async throws {
        try requireConfigured(.dom)
        let targetID = try targetID(for: nil)
        let target = try authorizedDocumentTarget(id: targetID)
        try await target.dom.hideHighlight()
        domState.clearPageHighlight()
    }

    package func domUndoRedoCommands() -> DOMUndoRedoCommands {
        return DOMUndoRedoCommands(
            store: domState,
            target: domState.capturedEditHistoryTarget(),
            fallbackTarget: currentPage,
            documentEpoch: domState.documentEpoch
        )
    }

    package func undoDOMChange() async throws {
        try await domUndoRedoCommands().undo()
    }

    package func redoDOMChange() async throws {
        try await domUndoRedoCommands().redo()
    }

    /// Enables or disables WebKit's element picker.
    public nonisolated(nonsending) func setElementPickerEnabled(
        _ isEnabled: Bool
    ) async throws {
        try requireConfigured(.dom)
        guard !isElementPickerTransitioning else {
            throw WebInspectorModelError.commandRejected(
                method: "DOM.setInspectModeEnabled",
                message: "An element-picker transition is already in progress."
            )
        }
        if isEnabled == ownsElementPickerLease {
            return
        }
        guard state == .attached,
              let feed = activeFeed else {
            throw modelStateError()
        }

        let expectedAttachmentGeneration = attachmentGeneration
        isElementPickerTransitioning = true
        defer {
            isElementPickerTransitioning = false
        }

        if isEnabled {
            var didAcquireLease = false
            ownsElementPickerLease = true
            do {
                try await feed.acquireElementPicker()
                didAcquireLease = true
                guard attachmentGeneration == expectedAttachmentGeneration,
                      activeFeed === feed,
                      state == .attached else {
                    throw TransitionError.superseded
                }
                guard ownsElementPickerLease else {
                    return
                }
                applyDOMStateEffects(
                    domState.setElementPickerEnabled(true)
                )
            } catch {
                let operationError = error
                ownsElementPickerLease = false
                guard didAcquireLease else {
                    throw operationError
                }
                do {
                    try await feed.releaseElementPicker()
                } catch {
                    throw WebInspectorScopeError(
                        operationError: operationError,
                        cleanupError: error
                    )
                }
                throw operationError
            }
            return
        }

        let cleanupResult: Result<Void, any Error>
        do {
            try await feed.releaseElementPicker()
            cleanupResult = .success(())
        } catch {
            cleanupResult = .failure(error)
        }
        ownsElementPickerLease = false
        applyDOMStateEffects(
            domState.setElementPickerEnabled(false)
        )
        switch cleanupResult {
        case .success:
            return
        case let .failure(cleanupError):
            throw cleanupError
        }
    }

    /// Reloads the inspected page.
    public nonisolated(nonsending) func reload(
        ignoringCache: Bool = false
    ) async throws {
        preconditionOwnerIsolation()
        let page = try currentPageOrThrow()
        try await page.page.reload(ignoringCache: ignoringCache)
    }

    /// Returns a CSS selector path for a DOM node.
    public func selectorPath(for node: DOMNode) throws -> String {
        try requireConfigured(.dom)
        try registeredNode(node)
        return try domState.currentTreeSnapshot(
            containing: [node]
        ).selectorPath(for: node.id)
    }

    package func selectorPath(for id: DOMNode.ID) throws -> String {
        try selectorPath(for: try requiredNode(for: id))
    }

    /// Returns an XPath expression for a DOM node.
    public func xPath(for node: DOMNode) throws -> String {
        try requireConfigured(.dom)
        try registeredNode(node)
        return try domState.currentTreeSnapshot(
            containing: [node]
        ).xPath(for: node.id)
    }

    package func xPath(for id: DOMNode.ID) throws -> String {
        try xPath(for: try requiredNode(for: id))
    }

    /// Creates a live DOM tree controller rooted at a current node.
    public func domTree(rootedAt node: DOMNode) throws -> DOMTreeController {
        try requireConfigured(.dom)
        return try domState.treeController(root: node)
    }

    package func rootTreeController() -> DOMTreeController {
        return domState.rootTreeController()
    }

    /// Runs an operation with one uniquely named binding-scoped Runtime group.
    public nonisolated(nonsending) func withRuntimeObjectGroup<Output>(
        named: String? = nil,
        _ operation: nonisolated(nonsending) (RuntimeObjectGroup) async throws -> Output
    ) async throws -> Output {
        let objectGroup = try makeRuntimeObjectGroup(named: named)
        let operationResult: Result<Output, any Error>
        do {
            operationResult = .success(try await operation(objectGroup))
        } catch {
            operationResult = .failure(error)
        }

        switch operationResult {
        case let .success(output):
            try await objectGroup.close()
            return output
        case let .failure(operationError):
            do {
                try await objectGroup.close()
            } catch {
                throw WebInspectorRuntimeScopeError(
                    operationError: operationError,
                    cleanupError: error
                )
            }
            throw operationError
        }
    }

    /// Creates live Network request results for a closed concrete query.
    ///
    /// The returned result already contains an atomic initial snapshot. Query
    /// evaluation, ordering, sectioning, and windowing run on the Network index
    /// actor rather than this context's owner actor.
    public nonisolated(nonsending) func networkRequests(
        matching query: NetworkQuery = NetworkQuery()
    ) async throws -> WebInspectorFetchedResults<NetworkRequest> {
        try requireConfigured(.network)
        return try await networkRequests.results(
            matching: query,
            modelContext: self
        )
    }

    /// Creates live Console message results for a closed concrete query.
    ///
    /// The returned result already contains an atomic initial snapshot. Query
    /// filtering, ordering, sectioning, and windowing run on the Console index
    /// actor rather than this context's owner actor.
    public nonisolated(nonsending) func consoleMessages(
        matching query: ConsoleQuery = ConsoleQuery()
    ) async throws -> WebInspectorFetchedResults<ConsoleMessage> {
        try requireConfigured(.console)
        return try await consoleMessages.results(
            matching: query,
            modelContext: self
        )
    }

    /// Clears WebKit's Console object group and lets the ordered clear event
    /// invalidate local message and remote-object identities.
    public nonisolated(nonsending) func clearConsoleMessages() async throws {
        try requireConfigured(.console)
        let page = try currentPageOrThrow()
        try await page.console.clearMessages()
    }

    /// Loads and returns the request's stable response-body resource.
    ///
    /// Concurrent callers for the same body join one protocol request. Cancelling
    /// one caller stops only that caller's wait; the shared request continues
    /// until it completes or the body becomes stale.
    public func responseBody(
        for request: NetworkRequest,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> NetworkBody {
        if request.id.canonicalStorage != nil {
            return try await loadCanonicalResponseBody(
                request.responseBody,
                isolation: isolation
            )
        }
        let body = request.responseBody
        do {
            try requireConfigured(.network)
            guard networkRequests.request(for: request.id) === request else {
                throw WebInspectorModelError.staleModel
            }
        } catch {
            failResponseBodyPreflight(body, with: error)
            throw error
        }

        let page: WebInspectorTarget?
        if case .available = body.phase {
            guard request.canFetchResponseBody else {
                // A response that has not reached loadingFinished is not a
                // terminal body failure. Keep the stable body retryable so a
                // later caller can fetch it after the request finishes.
                throw WebInspectorModelError.commandRejected(
                    method: "Network.getResponseBody",
                    message: "The response body is not available for this request."
                )
            }
            do {
                page = try currentPageOrThrow()
            } catch {
                failResponseBodyPreflight(body, with: error)
                throw error
            }
        } else {
            page = nil
        }

        let lease: NetworkBody.ResponseFetchLease
        switch body.acquireResponseFetch() {
        case .loaded:
            return body
        case let .failed(failure):
            try Self.throwResponseBodyFailure(failure)
        case let .waiter(existingLease):
            lease = existingLease
        case let .owner(newLease):
            guard let page else {
                preconditionFailure("A new response fetch requires a current page binding.")
            }
            lease = newLease
            let requestID = request.proxyID
            let backendResourceIdentifier = request.backendResourceIdentifier
            let completion = newLease.completion
            let task = Task { [weak body] in
                _ = isolation
                let result = await Self.loadResponseBody(
                    from: page,
                    requestID: requestID,
                    backendResourceIdentifier: backendResourceIdentifier
                )
                guard let body else {
                    completion.fulfill(.failure(WebInspectorProxyError.staleIdentifier))
                    return
                }
                body.finishResponseFetch(result, for: newLease)
            }
            body.installResponseFetchTask(task, for: newLease)
        }

        do {
            _ = try await lease.completion.value()
        } catch WebInspectorProxyError.staleIdentifier {
            // A response replacement invalidates the old wire command with
            // `staleIdentifier`, but that is a semantic model supersession,
            // not a terminal failure of the stable body resource. Preserve
            // the ProxyKit error only when the same model revision still owns
            // the command.
            guard body.isCurrentResponseFetch(lease) else {
                throw WebInspectorModelError.staleModel
            }
            throw WebInspectorProxyError.staleIdentifier
        }
        guard responseBodyFetchIsCurrent(
            lease,
            body: body,
            request: request
        ) else {
            throw WebInspectorModelError.staleModel
        }
        return body
    }

    package func loadCanonicalResponseBody(
        _ body: NetworkBody,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> NetworkBody {
        _ = isolation
        preconditionOwnerIsolation()
        try requireConfigured(.network)
        guard let requestID = body.boundCanonicalRequestID,
            let storage = requestID.canonicalStorage,
            let request: NetworkRequest = registeredModel(for: requestID),
            request.responseBody === body,
            request.modelContext === self
        else {
            throw WebInspectorModelError.staleModel
        }

        let coreForNewFetch: WebInspectorModelContainerCore?
        if case .available = body.phase {
            guard request.canFetchResponseBody else {
                throw WebInspectorModelError.commandRejected(
                    method: "Network.getResponseBody",
                    message: "The response body is not available for this request."
                )
            }
            guard let binding = containerRegistrationBinding else {
                throw WebInspectorModelError.detached
            }
            coreForNewFetch = binding.core
        } else {
            coreForNewFetch = nil
        }

        let lease: NetworkBody.ResponseFetchLease
        switch body.acquireResponseFetch() {
        case .loaded:
            return body
        case let .failed(failure):
            try Self.throwResponseBodyFailure(failure)
        case let .waiter(existingLease):
            lease = existingLease
        case let .owner(newLease):
            guard let core = coreForNewFetch else {
                preconditionFailure(
                    "An available canonical NetworkBody lost its Container Core preflight."
                )
            }
            lease = newLease
            let completion = newLease.completion
            let task = Task { [weak body] in
                _ = isolation
                let result = await Self.loadCanonicalResponseBody(
                    from: core,
                    requestID: storage
                )
                guard let body else {
                    completion.fulfill(
                        .failure(WebInspectorProxyError.staleIdentifier)
                    )
                    return
                }
                body.finishResponseFetch(result, for: newLease)
            }
            body.installResponseFetchTask(task, for: newLease)
        }

        do {
            _ = try await lease.completion.value()
        } catch WebInspectorProxyError.staleIdentifier {
            guard body.isCurrentResponseFetch(lease) else {
                throw WebInspectorModelError.staleModel
            }
            throw WebInspectorProxyError.staleIdentifier
        }
        guard let current: NetworkRequest = registeredModel(for: requestID),
            current === request,
            current.responseBody === body,
            body.isCurrentResponseFetch(lease)
        else {
            throw WebInspectorModelError.staleModel
        }
        return body
    }

    private func responseBodyFetchIsCurrent(
        _ lease: NetworkBody.ResponseFetchLease,
        body: NetworkBody,
        request: NetworkRequest
    ) -> Bool {
        networkRequests.request(for: request.id) === request
            && request.responseBody === body
            && body.isCurrentResponseFetch(lease)
    }

    nonisolated(nonsending) func updateNetworkQuery(
        _ query: NetworkQuery,
        for results: WebInspectorFetchedResults<NetworkRequest>
    ) async throws {
        preconditionOwnerIsolation()
        guard results.modelContext === self else {
            preconditionFailure("Network fetched results are not registered in this WebInspectorModelContext.")
        }
        try await networkRequests.update(query, for: results)
    }

    nonisolated(nonsending) func updateConsoleQuery(
        _ query: ConsoleQuery,
        for results: WebInspectorFetchedResults<ConsoleMessage>
    ) async throws {
        preconditionOwnerIsolation()
        guard results.modelContext === self else {
            preconditionFailure("Console fetched results are not registered in this WebInspectorModelContext.")
        }
        try await consoleMessages.update(query, for: results)
    }

    private nonisolated static func loadResponseBody(
        from page: WebInspectorTarget,
        requestID: Network.Request.ID,
        backendResourceIdentifier: Network.BackendResourceID?
    ) async -> Result<Network.Body, WebInspectorProxyError> {
        do {
            return .success(try await page.network.responseBody(
                for: requestID,
                backendResourceIdentifier: backendResourceIdentifier
            ))
        } catch is CancellationError {
            return .failure(.staleIdentifier)
        } catch let error as WebInspectorProxyError {
            return .failure(error)
        } catch {
            return .failure(.commandFailed(
                domain: "Network",
                method: "getResponseBody",
                message: String(describing: error)
            ))
        }
    }

    private nonisolated static func loadCanonicalResponseBody(
        from core: WebInspectorModelContainerCore,
        requestID: CanonicalNetworkRequestIDStorage
    ) async -> Result<Network.Body, WebInspectorProxyError> {
        do {
            return .success(
                try await core.loadNetworkResponseBody(for: requestID)
            )
        } catch is CancellationError {
            return .failure(.staleIdentifier)
        } catch let error as WebInspectorNetworkResponseBodyCommandError {
            switch error {
            case .closed:
                return .failure(.closed)
            case .staleRequest, .requestNotFound, .staleResponse:
                return .failure(.staleIdentifier)
            case let .proxy(proxyError):
                return .failure(proxyError)
            case .detached, .domainNotConfigured, .foreignStore,
                 .agentTargetUnavailable, .responseMissing,
                 .responseNotFinished, .webSocketIneligible,
                 .authorization, .invalidReply:
                return .failure(.commandFailed(
                    domain: "Network",
                    method: "getResponseBody",
                    message: String(describing: error)
                ))
            }
        } catch {
            return .failure(.commandFailed(
                domain: "Network",
                method: "getResponseBody",
                message: String(describing: error)
            ))
        }
    }

    private func failResponseBodyPreflight(
        _ body: NetworkBody,
        with error: any Error
    ) {
        guard let failure = Self.terminalResponseBodyFailure(from: error) else {
            return
        }
        switch body.phase {
        case .available, .fetching:
            body.failResponseFetch(
                failure,
                completionError: error
            )
        case .loaded, .failed:
            break
        }
    }

    private nonisolated static func terminalResponseBodyFailure(
        from error: any Error
    ) -> NetworkBody.Failure? {
        if let error = error as? WebInspectorModelError {
            switch error {
            case .detached, .synchronizing, .commandRejected:
                return nil
            case .domainNotConfigured, .staleModel:
                return .model(error)
            }
        }
        if let error = error as? Failure {
            return .context(error)
        }
        if let error = error as? TransitionError {
            switch error {
            case .superseded:
                return nil
            case .closed:
                return .transition(error)
            }
        }
        if let error = error as? WebInspectorProxyError {
            return .proxy(error)
        }
        preconditionFailure(
            "Unhandled Network response-body preflight error: \(String(reflecting: error))"
        )
    }

    private nonisolated static func throwResponseBodyFailure(
        _ failure: NetworkBody.Failure
    ) throws -> Never {
        switch failure {
        case .loadingFailed:
            throw failure
        case .model(let error):
            throw error
        case .context(let error):
            throw error
        case .transition(let error):
            throw error
        case .proxy(let error):
            throw error
        }
    }

    private func makeRuntimeObjectGroup(
        named name: String?
    ) throws -> RuntimeObjectGroup {
        try requireConfigured(.runtime)
        guard state == .attached,
              let binding,
              binding.didSynchronize,
              let target = currentPage else {
            throw modelStateError()
        }
        let id = runtimeState.createGroupID()
        let label = name.map(Self.runtimeObjectGroupLabel) ?? "group"
        let wireName = "WebInspectorDataKit.\(attachmentGeneration).\(binding.generation.rawValue).\(id.rawValue).\(label)"
        return RuntimeObjectGroup(
            modelContext: self,
            id: id,
            target: target,
            wireGroup: .other(wireName),
            attachmentGeneration: attachmentGeneration,
            pageGeneration: binding.generation
        )
    }

    package nonisolated(nonsending) func evaluate(
        _ expression: String,
        in context: RuntimeContext?,
        objectGroup: RuntimeObjectGroup
    ) async throws -> RuntimeEvaluation {
        try validate(objectGroup)
        let evaluationBinding = try runtimeState.evaluationBinding(for: context)
        let result = try await objectGroup.target.runtime.evaluate(
            expression,
            in: evaluationBinding.executionContextID,
            objectGroup: objectGroup.wireGroup
        )
        try validate(objectGroup)
        return try runtimeState.finishEvaluation(
            result,
            binding: evaluationBinding,
            groupID: objectGroup.id
        )
    }

    package nonisolated(nonsending) func properties(
        of object: RuntimeObject,
        ownProperties: Bool,
        objectGroup: RuntimeObjectGroup
    ) async throws -> [RuntimeProperty] {
        try validate(objectGroup)
        guard let objectBinding = try runtimeState.objectBinding(
            for: object,
            groupID: objectGroup.id
        ) else {
            return []
        }
        let descriptors = try await objectGroup.target.runtime.properties(
            of: objectBinding.remoteID,
            ownProperties: ownProperties
        )
        try validate(objectGroup)
        return try runtimeState.finishProperties(
            descriptors,
            binding: objectBinding,
            groupID: objectGroup.id
        )
    }

    package nonisolated(nonsending) func preview(
        of object: RuntimeObject,
        objectGroup: RuntimeObjectGroup
    ) async throws -> RuntimeObjectPreview {
        try validate(objectGroup)
        guard let objectBinding = try runtimeState.objectBinding(
            for: object,
            groupID: objectGroup.id
        ) else {
            throw WebInspectorModelError.staleModel
        }
        let preview = try await objectGroup.target.runtime.preview(
            of: objectBinding.remoteID
        )
        try validate(objectGroup)
        _ = try runtimeState.objectBinding(
            for: object,
            groupID: objectGroup.id
        )
        return preview
    }

    package nonisolated(nonsending) func close(
        objectGroup: RuntimeObjectGroup
    ) async throws {
        preconditionOwnerIsolation()
        guard objectGroup.modelContext === self else {
            throw WebInspectorModelError.staleModel
        }
        guard isCurrent(objectGroup) else {
            runtimeState.invalidateGroup(objectGroup.id)
            return
        }
        do {
            try await objectGroup.target.runtime.releaseObjectGroup(
                objectGroup.wireGroup
            )
            runtimeState.invalidateGroup(objectGroup.id)
        } catch WebInspectorProxyError.staleIdentifier {
            runtimeState.invalidateGroup(objectGroup.id)
            return
        }
    }

    private func validate(_ objectGroup: RuntimeObjectGroup) throws {
        preconditionOwnerIsolation()
        guard isCurrent(objectGroup) else {
            throw WebInspectorModelError.staleModel
        }
    }

    private func isCurrent(_ objectGroup: RuntimeObjectGroup) -> Bool {
        guard objectGroup.modelContext === self,
              runtimeState.isActiveGroup(objectGroup.id),
              objectGroup.attachmentGeneration == attachmentGeneration,
              let binding,
              binding.didSynchronize,
              binding.generation == objectGroup.pageGeneration,
              currentPage?.id == objectGroup.target.id,
              state == .attached else {
            return false
        }
        return true
    }

    private static func runtimeObjectGroupLabel(_ name: String) -> String {
        let scalars = name.unicodeScalars.prefix(64).map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        return scalars.isEmpty ? "group" : String(scalars)
    }

    @discardableResult
    private func registeredNode(
        _ node: DOMNode
    ) throws -> DOMNode {
        try domState.registeredNode(node)
    }

    private func currentPageOrThrow() throws -> WebInspectorTarget {
        guard let currentPage else {
            throw modelStateError()
        }
        return currentPage
    }

    private func domTarget(owning id: DOM.Node.ID) throws -> WebInspectorTarget {
        let targetID: WebInspectorTarget.ID
        if let scopedTargetRawValue = id.targetScopeRawValue {
            targetID = WebInspectorTarget.ID(scopedTargetRawValue)
        } else if let currentPageID = binding?.currentPageID {
            targetID = currentPageID
        } else {
            throw modelStateError()
        }
        return try authorizedDocumentTarget(id: targetID)
    }

    private func cssTarget(owning id: CSS.Style.ID) throws -> WebInspectorTarget {
        try authorizedDocumentTarget(id: targetID(for: id.targetScopeRawValue))
    }

    private func cssTarget(owning id: CSS.Rule.ID) throws -> WebInspectorTarget {
        try authorizedDocumentTarget(id: targetID(for: id.targetScopeRawValue))
    }

    private func cssTarget(owning id: CSS.StyleSheet.ID) throws -> WebInspectorTarget {
        try authorizedDocumentTarget(id: targetID(for: id.targetScopeRawValue))
    }

    private func targetID(for scopedRawValue: String?) throws -> WebInspectorTarget.ID {
        if let scopedRawValue {
            return WebInspectorTarget.ID(scopedRawValue)
        }
        guard let currentPageID = binding?.currentPageID else {
            throw modelStateError()
        }
        return currentPageID
    }

    private func authorizedDocumentTarget(
        id targetID: WebInspectorTarget.ID
    ) throws -> WebInspectorTarget {
        guard let binding,
              let target = binding.targets[targetID],
              case let .ready(epoch)? = binding.domAuthority[targetID],
              let authorized = authorizedTarget(target, documentEpoch: epoch) else {
            throw WebInspectorModelError.staleModel
        }
        return authorized
    }

    private func modelStateError() -> any Error {
        switch state {
        case .detached, .detaching:
            WebInspectorModelError.detached
        case .attaching, .synchronizing:
            WebInspectorModelError.synchronizing
        case .failed(let failure):
            failure
        case .closed:
            TransitionError.closed
        case .attached:
            WebInspectorModelError.staleModel
        }
    }

    private func requireConfigured(_ domain: Domain) throws {
        preconditionOwnerIsolation()
        guard configuredDomains.contains(domain) else {
            throw WebInspectorModelError.domainNotConfigured(domain)
        }
        if case let .failed(failure) = state {
            throw failure
        }
    }

    private static func markDOMUndoableStateIfNeeded(
        on target: WebInspectorTarget,
        options: DOMMutationPolicy
    ) async throws {
        switch options.undo {
        case .automatic:
            try await target.dom.markUndoableState()
        case .disabled:
            break
        }
    }

    private func recordDOMEditHistoryTarget(
        _ target: WebInspectorTarget,
        options: DOMMutationPolicy
    ) {
        domState.recordEditHistoryTarget(target, options: options)
    }

    private func validatedDeletionTargets(for nodes: [DOMNode]) throws -> [WebInspectorTarget] {
        var deletionTargets: [WebInspectorTarget] = []
        var firstTargetID: WebInspectorTarget.ID?
        for node in nodes {
            let target = try domTarget(owning: node.id.proxyID)
            if let firstTargetID, firstTargetID != target.id {
                throw WebInspectorProxyError.commandFailed(
                    domain: "DOM",
                    method: "removeNode",
                    message: "Deleting nodes from multiple DOM targets in one mutation is not supported."
                )
            }
            firstTargetID = target.id
            deletionTargets.append(target)
        }
        return deletionTargets
    }

    /// Inbound events may reference entities this context has not materialized:
    /// WebKit only reports what it has bound for this frontend, but binding can
    /// predate domain tracking (attach mid-flight) or outlive this context's
    /// index (evicted subtrees). Skipping is the protocol-correct response;
    /// `state = .failed` is reserved for terminal connection loss.
    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }

    private func failIfTerminal(_ error: Error, operation: String) {
        WebInspectorDataKitLog.debug("\(operation) failed: \(String(describing: error))")
    }

    private func transition(to newState: State) {
        state = newState
        notifyStatusChanged()
        WebInspectorDataKitLog.debug("context state=\(newState.logDescription)")
    }

    private func notifyStatusChanged() {
        guard statusRelay.hasContinuations else {
            return
        }
        statusRelay.yield(status)
    }

    private func applyDOMStateEffects(_ effects: DOMStateStore.Effects) {
        effects.discardedStyleNode?.setElementStyles(nil)

        if effects.statusChanged {
            notifyStatusChanged()
        }
        if effects.selectedStylesNeedRefresh {
            markSelectedStylesNeedsRefresh()
        }
    }

}

@available(
    *,
    unavailable,
    message: "contexts cannot be shared across concurrency contexts"
)
extension WebInspectorModelContext: @unchecked Sendable {}

extension WebInspectorModelContext {
    func apply(_ event: DOM.Event) {
        let effects = domState.apply(event, modelContext: self)
        applyDOMStateEffects(effects)
    }

    func applyDocument(
        _ node: DOM.Node,
        expectedEpoch: Int,
        reason: DOMTreeSnapshotReason = .initialDocument
    ) {
        guard let effects = domState.applyDocument(
            node,
            expectedEpoch: expectedEpoch,
            reason: reason,
            modelContext: self
        ) else {
            return
        }
        applyDOMStateEffects(effects)
    }

    package func seedDOMDocument(
        _ node: DOM.Node
    ) {
        let reason: DOMTreeSnapshotReason = domState.rootNode == nil ? .initialDocument : .documentUpdated
        applyDocument(
            node,
            expectedEpoch: domState.documentEpoch,
            reason: reason
        )
    }

    package func seedElementPickerEnabled(
        _ isEnabled: Bool
    ) {
        applyDOMStateEffects(
            domState.setElementPickerEnabled(isEnabled)
        )
    }

    /// Seeds the selected element node's stable CSS resource.
    package func seedSelectedNodeStyles(
        matchedStyles: CSS.MatchedStyles,
        inlineStyles: CSS.InlineStyles? = nil,
        computedProperties: [CSS.ComputedProperty] = []
    ) {
        guard let selectedNode = domState.selectedNode else {
            preconditionFailure("seedSelectedNodeStyles requires a selected node.")
        }
        guard selectedNode.nodeType == 1 else {
            preconditionFailure("seedSelectedNodeStyles requires a selected element node.")
        }
        let styles = selectedNode.elementStyles ?? CSSStyles(nodeID: selectedNode.id, modelContext: self)
        selectedNode.setElementStyles(styles)
        styles.load(
            matchedStyles: matchedStyles,
            inlineStyles: inlineStyles ?? CSS.InlineStyles(),
            computedProperties: computedProperties
        )
    }

    private func resetDOM() -> DOM? {
        cssInspectorBaselineStore.reset()
        let effects = domState.resetDocument()
        let pageHighlightDOM = effects.shouldClearPageHighlight
            ? currentPage?.dom
            : nil
        applyDOMStateEffects(effects)
        return pageHighlightDOM
    }
}
extension WebInspectorModelContext {
    /// Loads the stable CSS resource owned by a DOM element without changing
    /// DOM selection.
    public nonisolated(nonsending) func cssStyles(
        for node: DOMNode
    ) async throws -> CSSStyles {
        try requireConfigured(.css)
        try requireRegisteredDOMNode(node)
        guard node.nodeType == 1 else {
            throw WebInspectorModelError.commandRejected(
                method: "CSS.getMatchedStylesForNode",
                message: "CSS styles are only available for element DOM nodes."
            )
        }
        if let styles = node.elementStyles {
            switch styles.phase {
            case .loaded, .needsRefresh:
                return styles
            case .loading:
                preconditionFailure("Concurrent initial CSS loads require one caller-owned task.")
            case .failed, .unavailable:
                try await loadCSSStyles(for: node, into: styles)
                return styles
            }
        }
        let styles = CSSStyles(nodeID: node.id, modelContext: self)
        node.setElementStyles(styles)
        try await loadCSSStyles(for: node, into: styles)
        return styles
    }

    /// Explicitly refreshes a visible CSS resource after it becomes stale.
    public nonisolated(nonsending) func refreshCSSStyles(
        for node: DOMNode
    ) async throws {
        try requireConfigured(.css)
        try requireRegisteredDOMNode(node)
        guard let styles = node.elementStyles else {
            _ = try await cssStyles(for: node)
            return
        }
        try await loadCSSStyles(for: node, into: styles)
    }

    private nonisolated(nonsending) func loadCSSStyles(
        for node: DOMNode,
        into styles: CSSStyles
    ) async throws {
        try await styles.withExclusiveOperation {
            try await loadCSSStylesExclusively(for: node, into: styles)
        }
    }

    private nonisolated(nonsending) func loadCSSStylesExclusively(
        for node: DOMNode,
        into styles: CSSStyles
    ) async throws {
        if let canonicalID = node.id.canonicalStorage {
            guard let core = containerRegistrationBinding?.core else {
                throw WebInspectorModelError.staleModel
            }
            let generation = styles.beginCanonicalLoading()
            do {
                let resource = try await core.loadCSSResource(
                    for: canonicalID
                )
                try requireRegisteredDOMNode(node)
                guard styles.load(
                    resource,
                    generation: generation
                ) else {
                    throw WebInspectorModelError.staleModel
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WebInspectorModelError {
                throw error
            } catch let error as WebInspectorDOMCSSCommandError {
                switch error {
                case .staleCascade:
                    styles.markCanonicalNeedsRefresh()
                    throw WebInspectorModelError.staleModel
                case .closed,
                    .detached,
                    .foreignStore,
                    .staleDocument,
                    .nodeNotFound,
                    .identityRouteMismatch,
                    .staleNode:
                    styles.invalidateCanonicalOwner()
                    throw WebInspectorModelError.staleModel
                case .domainNotConfigured,
                    .styleSheetNotFound,
                    .agentTargetUnavailable,
                    .staleStyleSheet,
                    .proxy,
                    .authorization,
                    .invalidReply:
                    let proxyError = WebInspectorProxyError.commandFailed(
                        domain: "CSS",
                        method:
                            "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                        message: String(describing: error)
                    )
                    styles.fail(proxyError)
                    throw proxyError
                }
            } catch {
                let proxyError = WebInspectorProxyError.commandFailed(
                    domain: "CSS",
                    method:
                        "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                    message: String(describing: error)
                )
                styles.fail(proxyError)
                throw proxyError
            }
        }

        let target = try domTarget(owning: node.id.proxyID)
        styles.markLoading()
        do {
            let matched = try await target.css.matchedStyles(for: node.id.proxyID)
            try registeredNode(node)
            let inline = try await target.css.inlineStyles(for: node.id.proxyID)
            try registeredNode(node)
            let computed = try await target.css.computedStyle(for: node.id.proxyID)
            try registeredNode(node)
            styles.load(
                matchedStyles: matched,
                inlineStyles: inline,
                computedProperties: computed
            )
        } catch is CancellationError {
            // Preserve task cancellation so CSSStyles' operation boundary can
            // restore the last usable resource phase.
            throw CancellationError()
        } catch let error as WebInspectorProxyError {
            styles.fail(error)
            throw error
        } catch {
            let proxyError = WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            )
            styles.fail(proxyError)
            throw proxyError
        }
    }

    private func requireRegisteredDOMNode(
        _ node: DOMNode
    ) throws {
        if node.id.canonicalStorage != nil {
            guard registeredModel(for: node.id) === node else {
                throw WebInspectorModelError.staleModel
            }
            return
        }
        _ = try registeredNode(node)
    }

    public nonisolated(nonsending) func setCSSProperty(
        _ property: CSSStyleProperty,
        enabled: Bool,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try requireConfigured(.css)
        guard let styles = domState.styles(containing: property),
              property.beginMutation() else {
            throw WebInspectorModelError.staleModel
        }
        defer {
            property.endMutation()
        }
        return try await styles.withExclusiveOperation {
            try await loadCSSStylesForMutationIfNeeded(styles)
            guard let intent = styles.setStyleTextIntent(
                for: property,
                enabled: enabled
            ) else {
                throw WebInspectorModelError.staleModel
            }
            let target = try cssTarget(owning: intent.styleID)
            let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
            styles.applySetStyleText(result: result, for: property.id)
            let options = DOMMutationPolicy(undo: undo)
            domState.recordEditHistoryTarget(target, options: options)
            try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
            return makeDOMUndoCapability(policy: undo)
        }
    }

    public nonisolated(nonsending) func setCSSDeclarationText(
        _ text: String,
        for property: CSSStyleProperty,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try requireConfigured(.css)
        guard let styles = domState.styles(containing: property),
              property.beginMutation() else {
            throw WebInspectorModelError.staleModel
        }
        defer {
            property.endMutation()
        }
        return try await styles.withExclusiveOperation {
            try await loadCSSStylesForMutationIfNeeded(styles)
            guard let intent = styles.setDeclarationTextIntent(
                for: property,
                text: text
            ) else {
                throw WebInspectorModelError.staleModel
            }
            let target = try cssTarget(owning: intent.styleID)
            let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
            styles.applySetStyleText(result: result, for: property.id)
            let options = DOMMutationPolicy(undo: undo)
            domState.recordEditHistoryTarget(target, options: options)
            try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
            return makeDOMUndoCapability(policy: undo)
        }
    }

    private nonisolated(nonsending) func loadCSSStylesForMutationIfNeeded(
        _ styles: CSSStyles
    ) async throws {
        guard styles.phase != .loaded else {
            return
        }
        guard let node = domState.node(for: styles.id.nodeID),
              node.elementStyles === styles else {
            throw WebInspectorModelError.staleModel
        }
        try await loadCSSStylesExclusively(for: node, into: styles)
    }

    public nonisolated(nonsending) func setCSSRuleSelector(
        _ selector: String,
        for rule: CSSStyleRule,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try requireConfigured(.css)
        guard let id = rule.id,
              let styles = domState.styles(containing: id) else {
            throw WebInspectorModelError.staleModel
        }
        let target = try cssTarget(owning: id.proxyID)
        _ = try await target.css.setRuleSelector(id.proxyID, selector: selector)
        let options = DOMMutationPolicy(undo: undo)
        domState.recordEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        styles.markNeedsRefresh()
        return makeDOMUndoCapability(policy: undo)
    }

    public nonisolated(nonsending) func setCSSStyleSheetText(
        _ text: String,
        for styleSheetID: CSS.StyleSheet.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try requireConfigured(.css)
        let target = try cssTarget(owning: styleSheetID)
        try await target.css.setStyleSheetText(styleSheetID, text: text)
        let options = DOMMutationPolicy(undo: undo)
        domState.recordEditHistoryTarget(target, options: options)
        try await Self.markDOMUndoableStateIfNeeded(on: target, options: options)
        domState.markAllStylesNeedsRefresh()
        return makeDOMUndoCapability(policy: undo)
    }

    func apply(_ event: CSS.Event) {
        switch event {
        case .styleSheetChanged,
             .styleSheetAdded,
             .styleSheetRemoved,
             .mediaQueryResultChanged:
            domState.markAllStylesNeedsRefresh()
        case let .nodeLayoutFlagsChanged(id):
            domState.node(for: DOMNode.ID(id))?.elementStyles?.markNeedsRefresh()
        case .unknown:
            break
        }
    }

    private func markSelectedStylesNeedsRefresh() {
        domState.selectedNode?.elementStyles?.markNeedsRefresh()
    }
}

extension WebInspectorModelContext {
    @discardableResult
    package func seedNetworkRequest(
        requestID rawRequestID: String,
        url: String,
        method: String = "GET",
        resourceTypeRawValue: String?,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseMIMEType: String,
        responseStatus: Int,
        responseStatusText: String,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        initiator: Network.Initiator? = nil,
        timestamp: Double,
        encodedBodyLength: Int = 0
    ) -> NetworkRequest.ID {
        return networkRequests.seedRequest(
            requestID: rawRequestID,
            url: url,
            method: method,
            resourceTypeRawValue: resourceTypeRawValue,
            requestHeaders: requestHeaders,
            postData: postData,
            responseMIMEType: responseMIMEType,
            responseStatus: responseStatus,
            responseStatusText: responseStatusText,
            responseHeaders: responseHeaders,
            responseBody: responseBody,
            initiator: initiator,
            timestamp: timestamp,
            encodedBodyLength: encodedBodyLength,
            modelContext: self
        )
    }

    package func seedResponseBody(
        for requestID: NetworkRequest.ID,
        body: String,
        base64Encoded: Bool = false,
        size: Int? = nil,
        isTruncated: Bool = false
    ) {
        networkRequests.seedResponseBody(
            for: requestID,
            body: body,
            base64Encoded: base64Encoded,
            size: size,
            isTruncated: isTruncated
        )
    }

    package nonisolated(nonsending) func apply(
        _ event: Network.Event
    ) async {
        await networkRequests.apply(event, modelContext: self)
    }
}

extension WebInspectorModelContext {
    func apply(
        _ event: Console.Event,
        targetID: WebInspectorTarget.ID? = nil
    ) async {
        let effects = await consoleMessages.apply(
            event,
            targetID: targetID,
            modelContext: self,
            registerRuntimeObject: { [self] payload in
                runtimeState.registerConsoleParameter(
                    payload
                )
            }
        )
        // WebKit's Console agent releases its "console" Runtime object group
        // before emitting Console.messagesCleared. DataKit owns only the local
        // RuntimeObject registrations invalidated by that event.
        applyConsoleMessageEffects(effects)
    }

    private func applyConsoleMessageEffects(
        _ effects: ConsoleMessageStore.Effects
    ) {
        if effects.clearedAllMessages {
            runtimeState.removeAllConsoleOwnership()
            return
        }
        runtimeState.removeConsoleOwnership(
            from: effects.runtimeObjectsToUnregister
        )
    }

}

extension WebInspectorModelContext {
    func apply(
        _ event: Runtime.Event,
        targetID: WebInspectorTarget.ID? = nil,
        isCurrentPageTarget: Bool = true
    ) {
        runtimeState.apply(
            event,
            sourceTargetID: targetID,
            isCurrentPageTarget: isCurrentPageTarget
        )
    }
}
