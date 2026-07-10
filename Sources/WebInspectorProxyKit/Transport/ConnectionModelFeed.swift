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
        .console,
        .runtime,
    ]

    static func ordered(
        _ domains: Set<ModelDomain>
    ) -> [ModelDomain] {
        acquisitionOrder.filter(domains.contains)
    }

    static func normalized(
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
            [.console]
        case .runtime:
            [.runtime]
        }
    }

    var replayCapability: WebInspectorProxyEventDomain? {
        switch self {
        case .dom:
            nil
        case .css:
            .css
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

package struct ModelTargetSnapshot: Equatable, Sendable {
    /// The physical target currently bound to the semantic current-page feed.
    package let currentPageID: WebInspectorTarget.ID

    /// The physical main page followed by its frame targets in deterministic
    /// parent-before-child order.
    package let targets: [ModelTarget]

    package init(
        currentPageID: WebInspectorTarget.ID,
        targets: [ModelTarget]
    ) {
        self.currentPageID = currentPageID
        self.targets = targets
    }
}

package enum ModelTargetLifecycleEvent: Sendable {
    case targetCreated(ModelTarget)
    case targetDestroyed(ModelTarget)
    case didCommitProvisionalTarget(
        oldTargetID: WebInspectorTarget.ID,
        newTarget: ModelTarget
    )
    case frameNavigated(WebInspectorPageFrameLifecycle)
    case frameDetached(frameID: FrameID)
}

package enum ModelProtocolEvent: Sendable {
    case target(ModelTargetLifecycleEvent)
    case dom(target: ModelTarget, event: DOM.Event)
    case inspector(target: ModelTarget, event: Inspector.Event)
    case css(target: ModelTarget, event: CSS.Event)
    case network(target: ModelTarget, event: Network.Event)
    case console(target: ModelTarget, event: Console.Event)
    case runtime(target: ModelTarget, event: Runtime.Event)
}

package struct ModelDocumentEpoch: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package enum ModelBootstrapSnapshot: Sendable {
    case domDocument(
        target: ModelTarget,
        documentEpoch: ModelDocumentEpoch,
        root: DOM.Node
    )
}

package enum ConnectionModelFeedRecord: Sendable {
    case reset(WebInspectorPage.Generation)
    case targetSnapshot(
        generation: WebInspectorPage.Generation,
        through: UInt64,
        snapshot: ModelTargetSnapshot
    )
    /// The authoritative document-identity boundary for one physical target.
    ///
    /// Core publishes this after advancing `documentEpoch`, and before the
    /// replacement DOM bootstrap or any later DOM/CSS delta for that target.
    /// `DOM.documentUpdated` is not also projected as a model protocol event.
    case domDocumentInvalidated(
        generation: WebInspectorPage.Generation,
        sequence: UInt64,
        target: ModelTarget,
        documentEpoch: ModelDocumentEpoch
    )
    case event(
        generation: WebInspectorPage.Generation,
        sequence: UInt64,
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

    package func acquireElementPicker() async throws {
        try await owner.acquireModelFeedElementPicker(id)
    }

    package func releaseElementPicker() async throws {
        try await owner.releaseModelFeedElementPicker(id)
    }

    isolated deinit {
        mailbox.abandon()
    }
}
