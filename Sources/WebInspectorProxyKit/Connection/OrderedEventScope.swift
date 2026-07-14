import Foundation
import Synchronization

/// Controls the number of protocol events retained by an event scope.
public enum WebInspectorEventBufferingPolicy: Equatable, Sendable {
    case bounded(Int)
    case unbounded

    package func validatedCapacity() throws -> Int? {
        switch self {
        case let .bounded(capacity):
            guard capacity > 0 else {
                throw WebInspectorProxyError.invalidEventBufferCapacity(capacity)
            }
            return capacity
        case .unbounded:
            return nil
        }
    }
}

package struct WebInspectorOrderedScopeID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

package struct WebInspectorReplyBoundary: Hashable, Sendable {
    package let token: UUID
    package let watermark: WebInspectorEventSequence

    package init(token: UUID = UUID(), watermark: WebInspectorEventSequence) {
        self.token = token
        self.watermark = watermark
    }
}

package struct WebInspectorScopedReply<Value: Sendable>: Sendable {
    package let value: Value
    package let boundary: WebInspectorReplyBoundary
    package let generation: WebInspectorPage.Generation
    package let semanticTargetID: WebInspectorTarget.ID?
    package let agentTargetID: WebInspectorTarget.ID?
    package let semanticTarget: WebInspectorTarget?
    package let agentTarget: WebInspectorTarget?
}

package struct WebInspectorOrderedScopeDescriptor<Event: Sendable>: Sendable {
    package let selection: WebInspectorTargetSelectionPolicy
    package let decoders: [WebInspectorEventDecoder<Event>]
    package let capabilities: [WebInspectorDomainCapabilityDescriptor]

    package init(
        selection: WebInspectorTargetSelectionPolicy = .currentPage,
        decoders: [WebInspectorEventDecoder<Event>],
        capabilities: [WebInspectorDomainCapabilityDescriptor]
    ) {
        self.selection = selection
        self.decoders = decoders
        self.capabilities = capabilities
    }
}

package enum WebInspectorOrderedScopeRecord<Element: Sendable>: Sendable {
    case reset(WebInspectorPage.Generation)
    case event(WebInspectorPage.Generation, Element)
    case boundary(WebInspectorReplyBoundary)
}

package enum WebInspectorScopeDeliveryResult: Sendable {
    case enqueued
    case overflow
    case terminated
    case unrelated
}

package final class WebInspectorOrderedScopeMailbox<Element: Sendable>: Sendable {
    private enum Terminal: Sendable {
        case finished
        case failed(any Error)
    }

    private struct State: Sendable {
        var records: [WebInspectorOrderedScopeRecord<Element>] = []
        var startIndex = 0
        var bufferedEventCount = 0
        var waiter: CheckedContinuation<WebInspectorOrderedScopeRecord<Element>?, any Error>?
        var terminal: Terminal?

        mutating func append(_ record: WebInspectorOrderedScopeRecord<Element>) {
            records.append(record)
            if case .event = record { bufferedEventCount += 1 }
        }

        mutating func popFirst() -> WebInspectorOrderedScopeRecord<Element>? {
            guard startIndex < records.count else { return nil }
            let record = records[startIndex]
            startIndex += 1
            if case .event = record { bufferedEventCount -= 1 }
            if startIndex == records.count {
                records.removeAll(keepingCapacity: true)
                startIndex = 0
            } else if startIndex >= 64, startIndex * 2 >= records.count {
                records.removeFirst(startIndex)
                startIndex = 0
            }
            return record
        }
    }

    private let capacity: Int?
    private let state = Mutex(State())

    package init(capacity: Int?) { self.capacity = capacity }

    package func yieldReset(_ generation: WebInspectorPage.Generation) -> WebInspectorScopeDeliveryResult {
        yield(.reset(generation), countsAgainstCapacity: false)
    }

    package func yieldEvent(
        _ generation: WebInspectorPage.Generation,
        _ event: Element
    ) -> WebInspectorScopeDeliveryResult {
        yield(.event(generation, event), countsAgainstCapacity: true)
    }

    package func yieldBoundary(_ boundary: WebInspectorReplyBoundary) -> WebInspectorScopeDeliveryResult {
        yield(.boundary(boundary), countsAgainstCapacity: false)
    }

    package func finish(throwing error: (any Error)? = nil) {
        let waiter = state.withLock { state -> CheckedContinuation<WebInspectorOrderedScopeRecord<Element>?, any Error>? in
            guard state.terminal == nil else { return nil }
            state.terminal = error.map(Terminal.failed) ?? .finished
            guard state.startIndex == state.records.count else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        guard let waiter else { return }
        if let error { waiter.resume(throwing: error) }
        else { waiter.resume(returning: nil) }
    }

    package func nextEvent() async throws -> WebInspectorPageEvent<Element>? {
        while let record = try await nextRecord() {
            switch record {
            case let .reset(generation): return .reset(generation)
            case let .event(generation, event): return .event(generation, event)
            case .boundary:
                throw WebInspectorProxyError.replyBoundaryAlreadyOutstanding
            }
        }
        return nil
    }

    package func drain(
        through boundary: WebInspectorReplyBoundary
    ) async throws -> [WebInspectorPageEvent<Element>] {
        var events: [WebInspectorPageEvent<Element>] = []
        while let record = try await nextRecord() {
            switch record {
            case let .reset(generation): events.append(.reset(generation))
            case let .event(generation, event): events.append(.event(generation, event))
            case let .boundary(found):
                guard found.token == boundary.token else {
                    throw WebInspectorProxyError.replyBoundaryUnavailable
                }
                return events
            }
        }
        throw WebInspectorProxyError.replyBoundaryUnavailable
    }

    private func yield(
        _ record: WebInspectorOrderedScopeRecord<Element>,
        countsAgainstCapacity: Bool
    ) -> WebInspectorScopeDeliveryResult {
        let waiter = state.withLock { state -> CheckedContinuation<WebInspectorOrderedScopeRecord<Element>?, any Error>? in
            guard state.terminal == nil else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if countsAgainstCapacity, let capacity, state.bufferedEventCount >= capacity {
                state.terminal = .failed(WebInspectorProxyError.eventBufferOverflow(capacity: capacity))
                return nil
            }
            state.append(record)
            return nil
        }

        if let waiter {
            waiter.resume(returning: record)
            return .enqueued
        }
        return state.withLock { state in
            if case .failed(WebInspectorProxyError.eventBufferOverflow) = state.terminal {
                return .overflow
            }
            return state.terminal == nil ? .enqueued : .terminated
        }
    }

    private func nextRecord() async throws -> WebInspectorOrderedScopeRecord<Element>? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { state -> Result<WebInspectorOrderedScopeRecord<Element>?, any Error>? in
                    if let record = state.popFirst() { return .success(record) }
                    if let terminal = state.terminal {
                        switch terminal {
                        case .finished: return .success(nil)
                        case let .failed(error): return .failure(error)
                        }
                    }
                    guard state.waiter == nil else {
                        return .failure(WebInspectorProxyError.concurrentScopeConsumption)
                    }
                    state.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<WebInspectorOrderedScopeRecord<Element>?, any Error>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

package struct ConnectionOrderedScopeSink: Sendable {
    package let domains: Set<WebInspectorProtocolDomainToken>
    package let deliver: @Sendable (WebInspectorRoutedEventEnvelope) -> WebInspectorScopeDeliveryResult
    package let reset: @Sendable (WebInspectorPage.Generation) -> WebInspectorScopeDeliveryResult
    package let boundary: @Sendable (WebInspectorReplyBoundary) -> WebInspectorScopeDeliveryResult
    package let finish: @Sendable ((any Error)?) -> Void

    package init<Element: Sendable>(
        descriptor: WebInspectorOrderedScopeDescriptor<Element>,
        mailbox: WebInspectorOrderedScopeMailbox<Element>
    ) {
        let decoders = descriptor.decoders
        domains = Set(decoders.map(\.domain))
        deliver = { envelope in
            guard let decoder = decoders.first(where: { $0.domain == envelope.method.domain }) else {
                return .unrelated
            }
            do {
                return mailbox.yieldEvent(envelope.generation, try decoder.decode(envelope))
            } catch {
                mailbox.finish(throwing: WebInspectorEventDecodingError(envelope: envelope, error: error))
                return .terminated
            }
        }
        reset = { mailbox.yieldReset($0) }
        boundary = { mailbox.yieldBoundary($0) }
        finish = { mailbox.finish(throwing: $0) }
    }
}

package struct ConnectionOrderedScopeRegistry: Sendable {
    package struct Entry: Sendable {
        package let selection: WebInspectorTargetSelectionPolicy
        package let descriptorCapabilities: [WebInspectorDomainCapabilityDescriptor]
        package let sink: ConnectionOrderedScopeSink
        package var selectedTargets: Set<ProtocolTarget.ID>
        package var leases: [ConnectionCapabilityRegistry.Lease]
        package var deliveryIsActive: Bool
        package var outstandingBoundary: WebInspectorReplyBoundary?
    }

    package var entries: [WebInspectorOrderedScopeID: Entry] = [:]

    package init() {}
}

package struct WebInspectorOrderedEventScope<Element: Sendable>: Sendable {
    package let id: WebInspectorOrderedScopeID
    private let proxyReference: WebInspectorProxyReference
    private let mailbox: WebInspectorOrderedScopeMailbox<Element>

    package init(
        id: WebInspectorOrderedScopeID,
        proxyReference: WebInspectorProxyReference,
        mailbox: WebInspectorOrderedScopeMailbox<Element>
    ) {
        self.id = id
        self.proxyReference = proxyReference
        self.mailbox = mailbox
    }

    package var events: AsyncThrowingStream<WebInspectorPageEvent<Element>, any Error> {
        AsyncThrowingStream { [mailbox] in try await mailbox.nextEvent() }
    }

    package func command<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>
    ) async throws -> WebInspectorScopedReply<Result> {
        guard let proxy = proxyReference.resolve() else { throw WebInspectorProxyError.closed }
        return try await proxy.send(command, in: id)
    }

    package func drain(
        through boundary: WebInspectorReplyBoundary
    ) async throws -> [WebInspectorPageEvent<Element>] {
        let events = try await mailbox.drain(through: boundary)
        guard let proxy = proxyReference.resolve() else { throw WebInspectorProxyError.closed }
        try await proxy.completeBoundary(boundary, in: id)
        return events
    }

    package func close() async {
        guard let proxy = proxyReference.resolve() else { return }
        await proxy.closeScope(id)
    }
}
