import Foundation
import Synchronization

package enum ModelDomain: Hashable, Sendable {
    case dom
    case css
    case network
    case console
    case runtime

    static let acquisitionOrder: [ModelDomain] = [
        .dom,
        .css,
        .network,
        .runtime,
        .console,
    ]

    static func ordered(
        _ domains: Set<ModelDomain>
    ) -> [ModelDomain] {
        acquisitionOrder.filter(domains.contains)
    }

    package static func normalized(
        _ domains: Set<ModelDomain>
    ) -> Set<ModelDomain> {
        guard domains.contains(.css) else {
            return domains
        }
        var normalizedDomains = domains
        normalizedDomains.insert(.dom)
        return normalizedDomains
    }

    var capabilityDependencies: [WebInspectorProxyEventDomain] {
        switch self {
        case .dom:
            [.dom]
        case .css:
            [.dom, .css]
        case .network:
            [.network]
        case .console:
            // Console parameters can retain Runtime remote objects. Arm the
            // Runtime lifecycle before Console delivery without projecting
            // RuntimeContext state unless `.runtime` was explicitly requested.
            [.runtime, .console]
        case .runtime:
            [.runtime]
        }
    }

    var replayCapability: WebInspectorProxyEventDomain? {
        switch self {
        case .dom:
            nil
        case .css:
            nil
        case .network:
            .network
        case .console:
            .console
        case .runtime:
            .runtime
        }
    }
}

package struct ModelTarget: Equatable, Sendable {
    package let id: WebInspectorTarget.ID
    package let kind: WebInspectorTarget.Kind
    package let frameID: FrameID?
    package let parentFrameID: FrameID?

    package init(
        id: WebInspectorTarget.ID,
        kind: WebInspectorTarget.Kind,
        frameID: FrameID?,
        parentFrameID: FrameID?
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
        self.parentFrameID = parentFrameID
    }
}

extension ModelTarget {
    init?(record: ProtocolTarget.Record) {
        guard let kind = WebInspectorTarget.Kind(protocolKind: record.kind) else {
            return nil
        }
        self.init(
            id: WebInspectorTarget.ID(record.id.rawValue),
            kind: kind,
            frameID: record.frameID.map { FrameID($0.rawValue) },
            parentFrameID: record.parentFrameID.map { FrameID($0.rawValue) }
        )
    }
}

package struct ModelNavigationEpoch: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct ModelDOMBindingEpoch: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct ModelRuntimeBindingEpoch: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct ModelConsoleBindingEpoch: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct ModelEventScope: Equatable, Sendable {
    package let generation: WebInspectorPage.Generation
    /// The best available semantic model target for the event.
    ///
    /// Agent-wide or identifier-only events use `agentTarget`; reducers resolve
    /// existing semantic membership from `agentTarget` and the raw identifier.
    package let target: ModelTarget
    /// The physical protocol agent that owns raw identifiers and commands.
    package let agentTarget: ModelTarget
    package let navigationEpoch: ModelNavigationEpoch
    package let domBindingEpoch: ModelDOMBindingEpoch?
    package let runtimeBindingEpoch: ModelRuntimeBindingEpoch?
    package let consoleBindingEpoch: ModelConsoleBindingEpoch?

    package init(
        generation: WebInspectorPage.Generation,
        target: ModelTarget,
        agentTarget: ModelTarget,
        navigationEpoch: ModelNavigationEpoch,
        domBindingEpoch: ModelDOMBindingEpoch?,
        runtimeBindingEpoch: ModelRuntimeBindingEpoch?,
        consoleBindingEpoch: ModelConsoleBindingEpoch?
    ) {
        self.generation = generation
        self.target = target
        self.agentTarget = agentTarget
        self.navigationEpoch = navigationEpoch
        self.domBindingEpoch = domBindingEpoch
        self.runtimeBindingEpoch = runtimeBindingEpoch
        self.consoleBindingEpoch = consoleBindingEpoch
    }
}

package struct ModelTargetState: Equatable, Sendable {
    package let target: ModelTarget
    package let navigationEpoch: ModelNavigationEpoch
    package let domBindingEpoch: ModelDOMBindingEpoch?
    package let runtimeBindingEpoch: ModelRuntimeBindingEpoch?
    package let consoleBindingEpoch: ModelConsoleBindingEpoch?

    package init(
        target: ModelTarget,
        navigationEpoch: ModelNavigationEpoch,
        domBindingEpoch: ModelDOMBindingEpoch?,
        runtimeBindingEpoch: ModelRuntimeBindingEpoch?,
        consoleBindingEpoch: ModelConsoleBindingEpoch?
    ) {
        self.target = target
        self.navigationEpoch = navigationEpoch
        self.domBindingEpoch = domBindingEpoch
        self.runtimeBindingEpoch = runtimeBindingEpoch
        self.consoleBindingEpoch = consoleBindingEpoch
    }
}

package struct ModelTargetSnapshot: Equatable, Sendable {
    /// The physical target currently bound to the semantic current-page feed.
    package let currentPageID: WebInspectorTarget.ID

    /// The physical main page followed by its frame targets in deterministic
    /// parent-before-child order.
    package let targets: [ModelTargetState]

    package init(
        currentPageID: WebInspectorTarget.ID,
        targets: [ModelTargetState]
    ) {
        self.currentPageID = currentPageID
        self.targets = targets
    }
}

package enum ModelTargetLifecycleEvent: Sendable {
    case targetCreated
    case targetDestroyed
    case didCommitProvisionalTarget(oldTargetID: WebInspectorTarget.ID)
    /// `isNewLoader` is scoped by current-page frame identity, independently
    /// from the delivering Runtime agent's binding epoch.
    case frameNavigated(
        WebInspectorPageFrameLifecycle,
        isNewLoader: Bool
    )
    case frameDetached(frameID: FrameID)
}

package enum ModelProtocolEvent: Sendable {
    case target(ModelTargetLifecycleEvent)
    case dom(DOM.Event)
    case inspector(Inspector.Event)
    case css(CSS.Event)
    case network(Network.Event)
    case console(Console.Event)
    case runtime(Runtime.Event)
}

package struct ModelCSSStyleSheet: Sendable {
    package let scope: ModelEventScope
    package let header: CSS.StyleSheetHeader

    package init(scope: ModelEventScope, header: CSS.StyleSheetHeader) {
        self.scope = scope
        self.header = header
    }
}

package enum ModelBootstrapSnapshot: Sendable {
    case domDocument(
        scope: ModelEventScope,
        root: DOM.Node
    )
    case cssStyleSheets([ModelCSSStyleSheet])
}

package enum ConnectionModelFeedRecord: Sendable {
    case reset(WebInspectorPage.Generation)
    case targetSnapshot(
        generation: WebInspectorPage.Generation,
        through: UInt64,
        snapshot: ModelTargetSnapshot
    )
    /// The authoritative DOM-binding boundary for one physical target.
    ///
    /// Core publishes this after advancing `domBindingEpoch`, and before the
    /// replacement DOM bootstrap or any later DOM/CSS delta for that target.
    /// `DOM.documentUpdated` is not also projected as a model protocol event.
    case domDocumentInvalidated(
        sequence: UInt64,
        scope: ModelEventScope
    )
    case event(
        sequence: UInt64,
        scope: ModelEventScope,
        payload: ModelProtocolEvent
    )
    case replayComplete(
        generation: WebInspectorPage.Generation,
        domain: ModelDomain,
        through: UInt64
    )
    case bootstrapSnapshot(
        generation: WebInspectorPage.Generation,
        domain: ModelDomain,
        sequence: UInt64,
        payload: ModelBootstrapSnapshot
    )
    case bootstrapComplete(
        generation: WebInspectorPage.Generation,
        domain: ModelDomain,
        through: UInt64
    )
    case synchronizationComplete(
        generation: WebInspectorPage.Generation,
        through: UInt64
    )
}

package struct ConnectionModelFeedID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package struct ConnectionModelElementPickerLeaseID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A caller-owned element-picker capability lease for one model feed.
///
/// Copies identify the same lease. The caller that creates a lease must
/// balance a successful `acquire()` with `release()`; releasing another
/// caller's picker mode is impossible because Core routes both operations by
/// this identity.
package struct ConnectionModelElementPickerLease: Sendable {
    package let id: ConnectionModelElementPickerLeaseID
    private let feedID: ConnectionModelFeedID
    private let owner: ConnectionCore

    package init(
        id: ConnectionModelElementPickerLeaseID = .init(),
        feedID: ConnectionModelFeedID,
        owner: ConnectionCore
    ) {
        self.id = id
        self.feedID = feedID
        self.owner = owner
    }

    package func acquire() async throws {
        try await owner.acquireModelFeedElementPicker(feedID, leaseID: id)
    }

    package func release() async throws {
        try await owner.releaseModelFeedElementPicker(feedID, leaseID: id)
    }
}

package enum ConnectionModelFeedDeliveryResult: Sendable {
    case enqueued
    case terminated
}

package enum ConnectionModelFeedError: Error, Equatable, Sendable {
    case connectionAlreadyUsedByDirectConsumer
    case alreadyOpen
    /// A configured domain rejected the capability or document bootstrap that
    /// is required to construct or refresh its authoritative model state.
    case bootstrapFailed(domain: ModelDomain, message: String)
    case consumerTerminated
}

package final class ConnectionModelFeedMailbox: Sendable {
    private enum Terminal {
        case finished
        case failed(any Error)
    }

    private struct State {
        var pendingRecords: [ConnectionModelFeedRecord] = []
        var pendingRecordStartIndex = 0
        var waiter: CheckedContinuation<ConnectionModelFeedRecord?, any Error>?
        var terminal: Terminal?
        var iteratorWasCreated = false

        mutating func removeFirstRecord() -> ConnectionModelFeedRecord? {
            guard pendingRecordStartIndex < pendingRecords.count else {
                return nil
            }
            let record = pendingRecords[pendingRecordStartIndex]
            pendingRecordStartIndex += 1
            if pendingRecordStartIndex == pendingRecords.count {
                pendingRecords.removeAll(keepingCapacity: true)
                pendingRecordStartIndex = 0
            } else if pendingRecordStartIndex >= 64,
                      pendingRecordStartIndex * 2 >= pendingRecords.count {
                pendingRecords.removeFirst(pendingRecordStartIndex)
                pendingRecordStartIndex = 0
            }
            return record
        }

        var pendingRecordCount: Int {
            pendingRecords.count - pendingRecordStartIndex
        }

        mutating func discardPendingRecords() {
            pendingRecords.removeAll(keepingCapacity: false)
            pendingRecordStartIndex = 0
        }
    }

    private let state = Mutex(State())

    package init() {}

    package func claimIterator() {
        state.withLock { state in
            precondition(
                !state.iteratorWasCreated,
                "A connection model feed supports exactly one consumer iterator."
            )
            state.iteratorWasCreated = true
        }
    }

    package func enqueue(
        _ record: ConnectionModelFeedRecord
    ) -> ConnectionModelFeedDeliveryResult {
        let result = state.withLock { state -> (
            result: ConnectionModelFeedDeliveryResult,
            waiter: CheckedContinuation<ConnectionModelFeedRecord?, any Error>?
        ) in
            guard state.terminal == nil else {
                return (.terminated, nil)
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return (.enqueued, waiter)
            }
            state.pendingRecords.append(record)
            return (.enqueued, nil)
        }
        result.waiter?.resume(returning: record)
        return result.result
    }

    package func finish(throwing error: (any Error)? = nil) {
        let waiter = state.withLock { state in
            guard state.terminal == nil else {
                return nil as CheckedContinuation<ConnectionModelFeedRecord?, any Error>?
            }
            if let error {
                state.terminal = .failed(error)
            } else {
                state.terminal = .finished
            }
            guard state.pendingRecordCount == 0 else {
                return nil
            }
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        guard let waiter else {
            return
        }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: nil)
        }
    }

    package func poison(throwing error: any Error) {
        let waiter = state.withLock { state in
            state.discardPendingRecords()
            guard state.terminal == nil else {
                return nil as CheckedContinuation<ConnectionModelFeedRecord?, any Error>?
            }
            state.terminal = .failed(error)
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: error)
    }

    package func abandon() {
        let waiter = state.withLock { state in
            guard state.terminal == nil else {
                return nil as CheckedContinuation<ConnectionModelFeedRecord?, any Error>?
            }
            state.terminal = .finished
            guard state.pendingRecordCount == 0 else {
                return nil
            }
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }

    fileprivate func next() async throws -> ConnectionModelFeedRecord? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<ConnectionModelFeedRecord?, any Error>? in
                    if let record = state.removeFirstRecord() {
                        return .success(record)
                    }
                    if let terminal = state.terminal {
                        switch terminal {
                        case .finished:
                            return .success(nil)
                        case let .failed(error):
                            return .failure(error)
                        }
                    }
                    precondition(
                        state.waiter == nil,
                        "A connection model feed cannot have concurrent next() calls."
                    )
                    state.waiter = continuation
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: { [self] in
            cancelConsumer()
        }
    }

    private func cancelConsumer() {
        let cancellation = CancellationError()
        let waiter = state.withLock { state in
            state.discardPendingRecords()
            guard state.terminal == nil else {
                return nil as CheckedContinuation<ConnectionModelFeedRecord?, any Error>?
            }
            state.terminal = .failed(cancellation)
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: cancellation)
    }
}

package struct ConnectionModelFeedRecords: AsyncSequence, Sendable {
    package typealias Element = ConnectionModelFeedRecord

    package struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        private let mailbox: ConnectionModelFeedMailbox

        fileprivate init(mailbox: ConnectionModelFeedMailbox) {
            self.mailbox = mailbox
        }

        package mutating func next() async throws -> ConnectionModelFeedRecord? {
            try await mailbox.next()
        }
    }

    private let mailbox: ConnectionModelFeedMailbox

    fileprivate init(mailbox: ConnectionModelFeedMailbox) {
        self.mailbox = mailbox
    }

    package func makeAsyncIterator() -> AsyncIterator {
        mailbox.claimIterator()
        return AsyncIterator(mailbox: mailbox)
    }
}

package actor ConnectionModelFeed {
    package nonisolated let id: ConnectionModelFeedID
    package nonisolated let records: ConnectionModelFeedRecords
    private nonisolated let owner: ConnectionCore
    private nonisolated let mailbox: ConnectionModelFeedMailbox

    package init(
        id: ConnectionModelFeedID,
        owner: ConnectionCore,
        mailbox: ConnectionModelFeedMailbox
    ) {
        self.id = id
        self.owner = owner
        self.mailbox = mailbox
        records = ConnectionModelFeedRecords(mailbox: mailbox)
    }

    package func close() async throws {
        try await owner.closeModelFeed(id)
    }

    package nonisolated func makeElementPickerLease()
        -> ConnectionModelElementPickerLease
    {
        ConnectionModelElementPickerLease(feedID: id, owner: owner)
    }

    isolated deinit {
        mailbox.abandon()
    }
}
