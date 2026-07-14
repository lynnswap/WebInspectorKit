import Foundation
import Synchronization
import WebInspectorProxyKit

/// The narrow physical-session capability handed to one semantic feature.
///
/// It deliberately exposes no container or context object. A feature can open
/// ordered protocol scopes through the page and commit immutable mutations
/// through the store sink passed to `run`.
package struct WebInspectorFeatureConnection: Sendable {
    package let page: WebInspectorPage
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let storeID: WebInspectorContainerStoreID

    package init(
        page: WebInspectorPage,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        storeID: WebInspectorContainerStoreID
    ) {
        self.page = page
        self.attachmentGeneration = attachmentGeneration
        self.storeID = storeID
    }
}

/// Common lifecycle integration for first-party semantic features.
///
/// Protocol decoding, bootstrap, reducer state, command waiters, and recovery
/// remain concrete actor responsibilities. The container is the only caller
/// of `run` and `close`.
package protocol WebInspectorModelFeature: Actor {
    static var id: WebInspectorFeatureID { get }

    func run(
        connection: WebInspectorFeatureConnection,
        store: WebInspectorModelStoreSink
    ) async -> WebInspectorFeatureTermination

    func retry() async
    func close() async
}

package enum WebInspectorFeatureTermination: Sendable {
    case detached
    case connectionFailed(WebInspectorConnectionFailure)
    case containerClosed
}

package struct WebInspectorFeatureTarget: Equatable, Hashable, Sendable {
    package enum Kind: Equatable, Hashable, Sendable {
        case page
        case frame
        case worker
        case other(String)
    }

    package let id: WebInspectorTarget.ID
    package let kind: Kind
    package let frameID: FrameID?

    package init(
        id: WebInspectorTarget.ID,
        kind: Kind,
        frameID: FrameID?
    ) {
        self.id = id
        self.kind = kind
        self.frameID = frameID
    }

    package init(_ target: WebInspectorTarget) {
        id = target.id
        if target.kind == .page {
            kind = .page
        } else if target.kind == .frame {
            kind = .frame
        } else if target.kind == .worker || target.kind == .serviceWorker {
            kind = .worker
        } else {
            kind = .other(target.kind.rawValue)
        }
        frameID = target.frameID
    }
}

/// One decoded event together with the route authority fixed by ProxyKit's
/// connection FIFO.
package struct WebInspectorFeatureEvent<Value: Sendable>: Sendable {
    package let sequence: UInt64
    package let generation: WebInspectorPageGeneration
    package let semanticTarget: WebInspectorFeatureTarget
    package let agentTarget: WebInspectorFeatureTarget
    package let method: String
    package let value: Value

    package init(
        sequence: UInt64,
        generation: WebInspectorPageGeneration,
        semanticTarget: WebInspectorFeatureTarget,
        agentTarget: WebInspectorFeatureTarget,
        method: String,
        value: Value
    ) {
        self.sequence = sequence
        self.generation = generation
        self.semanticTarget = semanticTarget
        self.agentTarget = agentTarget
        self.method = method
        self.value = value
    }
}

package struct WebInspectorFeatureEventScope: Equatable, Sendable {
    package let generation: WebInspectorPageGeneration
    package let semanticTarget: WebInspectorFeatureTarget
    package let agentTarget: WebInspectorFeatureTarget

    package var semanticTargetID: WebInspectorTarget.ID { semanticTarget.id }
    package var agentTargetID: WebInspectorTarget.ID { agentTarget.id }
    package var semanticTargetKind: WebInspectorFeatureTarget.Kind {
        semanticTarget.kind
    }
    package var semanticFrameID: FrameID? { semanticTarget.frameID }

    package init<Value>(_ event: WebInspectorFeatureEvent<Value>) {
        generation = event.generation
        semanticTarget = event.semanticTarget
        agentTarget = event.agentTarget
    }

    package init(
        generation: WebInspectorPageGeneration,
        semanticTarget: WebInspectorFeatureTarget,
        agentTarget: WebInspectorFeatureTarget
    ) {
        self.generation = generation
        self.semanticTarget = semanticTarget
        self.agentTarget = agentTarget
    }
}

package struct WebInspectorRecoveryFingerprint: Hashable, Sendable {
    package let code: String
    package let phase: String
    package let method: String?

    package init(
        code: String,
        phase: String,
        method: String? = nil
    ) {
        self.code = code
        self.phase = phase
        self.method = method
    }
}

/// Bounds automatic feature-local recovery independently for one generation.
package struct WebInspectorFeatureRecoveryBudget: Sendable {
    package enum Decision: Equatable, Sendable {
        case retry
        case repeatedFingerprint
        case generationBudgetExhausted
    }

    private(set) var generation: WebInspectorPageGeneration?
    private(set) var attemptedFingerprints: Set<WebInspectorRecoveryFingerprint>
    private(set) var automaticAttemptCount: Int
    package let maximumAutomaticAttempts: Int

    package init(maximumAutomaticAttempts: Int = 3) {
        self.maximumAutomaticAttempts = maximumAutomaticAttempts
        generation = nil
        attemptedFingerprints = []
        automaticAttemptCount = 0
    }

    package mutating func begin(
        generation proposedGeneration: WebInspectorPageGeneration,
        explicitRetry: Bool = false
    ) {
        guard explicitRetry || generation != proposedGeneration else { return }
        generation = proposedGeneration
        attemptedFingerprints.removeAll(keepingCapacity: true)
        automaticAttemptCount = 0
    }

    package mutating func consume(
        _ fingerprint: WebInspectorRecoveryFingerprint,
        generation proposedGeneration: WebInspectorPageGeneration
    ) -> Decision {
        begin(generation: proposedGeneration)
        guard attemptedFingerprints.insert(fingerprint).inserted else {
            return .repeatedFingerprint
        }
        guard automaticAttemptCount < maximumAutomaticAttempts else {
            return .generationBudgetExhausted
        }
        automaticAttemptCount += 1
        return .retry
    }
}

package final class WebInspectorFeatureCloseSignal: Sendable {
    private let closed = Atomic<Bool>(false)

    package init() {}

    package var isClosed: Bool {
        closed.load(ordering: .acquiring)
    }

    package func close() {
        closed.store(true, ordering: .releasing)
    }
}

package func webInspectorFailureDescription(
    _ error: any Error,
    code: String,
    phase: String
) -> WebInspectorFailureDescription {
    WebInspectorFailureDescription(
        code: code,
        phase: phase,
        message: String(describing: error)
    )
}

package func webInspectorLogFeatureTransition(
    feature: WebInspectorFeatureID,
    from: WebInspectorFeatureState,
    to: WebInspectorFeatureState,
    fingerprint: WebInspectorRecoveryFingerprint? = nil,
    revision: WebInspectorStoreRevision? = nil
) {
    WebInspectorDataKitLog.debug(
        "feature=\(feature.name) from=\(from) to=\(to) "
            + "fingerprint=\(String(describing: fingerprint)) "
            + "revision=\(String(describing: revision?.rawValue))"
    )
}
