import Foundation
import WebInspectorProxyKit

/// The CSS domain leases one `WebInspectorContext` holds, one per target
/// whose styles it has read.
///
/// Calls must come from the context's actor.
@MainActor
final class CSSStyleTrackingLeases {
    private struct Key: Hashable {
        var targetID: WebInspectorTarget.ID
        var pageBindingID: String?

        init(_ target: WebInspectorTarget) {
            targetID = target.id
            pageBindingID = target.pageBindingID
        }
    }

    private struct Acquisition {
        var generation: UInt64
        var target: WebInspectorTarget
        var task: Task<Void, any Error>
    }

    private let domainEnablement: WebInspectorDomainEnablementRegistry
    private var targets: [Key: WebInspectorTarget] = [:]
    private var acquisitions: [Key: Acquisition] = [:]
    private var nextAcquisitionGeneration: UInt64 = 0

    init(domainEnablement: WebInspectorDomainEnablementRegistry) {
        self.domainEnablement = domainEnablement
    }

    /// Acquires the CSS lease for `target` unless this context already holds
    /// it. Returns false when the lease was discarded while it was being
    /// acquired.
    func ensure(
        on target: WebInspectorTarget
    ) async throws -> Bool {
        let key = Key(target)
        if targets[key] != nil {
            return true
        }

        let acquisition: Acquisition
        if let existing = acquisitions[key] {
            acquisition = existing
        } else {
            let generation = nextAcquisitionGeneration
            nextAcquisitionGeneration += 1
            let registry = domainEnablement
            let task = Task<Void, any Error> {
                try await registry.acquireStyleAccess(on: target)
            }
            acquisition = Acquisition(
                generation: generation,
                target: target,
                task: task
            )
            acquisitions[key] = acquisition
        }

        do {
            try await acquisition.task.value
        } catch {
            if acquisitions[key]?.generation == acquisition.generation {
                acquisitions[key] = nil
            }
            throw error
        }

        if targets[key] != nil {
            return true
        }
        guard acquisitions[key]?.generation == acquisition.generation else {
            return false
        }
        acquisitions[key] = nil
        targets[key] = target
        return true
    }

    /// Drops every lease without sending `CSS.disable`.
    func discardAll() async {
        let enabledTargets = Self.sorted(Array(targets.values))
        let pendingAcquisitions = Self.sorted(Array(acquisitions.values))
        targets = [:]
        acquisitions = [:]

        for target in enabledTargets {
            await domainEnablement.discardStyleAccess(on: target)
        }
        for acquisition in pendingAcquisitions {
            do {
                try await acquisition.task.value
                await domainEnablement.discardStyleAccess(on: acquisition.target)
            } catch {
                // No release is valid here: a failed registry acquisition
                // never creates a lease.
            }
        }
    }

    /// Drops the leases of a destroyed target without sending `CSS.disable`.
    func discard(forDestroyedTargetID targetID: WebInspectorTarget.ID) {
        let enabledKeys = targets.keys.filter { $0.targetID == targetID }
        let enabledTargets = Self.sorted(enabledKeys.compactMap { key in
            targets.removeValue(forKey: key)
        })
        let pendingKeys = acquisitions.keys.filter { $0.targetID == targetID }
        let pendingAcquisitions = Self.sorted(pendingKeys.compactMap { key in
            acquisitions.removeValue(forKey: key)
        })
        guard enabledTargets.isEmpty == false || pendingAcquisitions.isEmpty == false else {
            return
        }

        let registry = domainEnablement
        Task {
            for target in enabledTargets {
                await registry.discardStyleAccess(on: target)
            }
            for acquisition in pendingAcquisitions {
                do {
                    try await acquisition.task.value
                    await registry.discardStyleAccess(on: acquisition.target)
                } catch {
                    // No release is valid here: a failed registry acquisition
                    // never creates a lease.
                }
            }
        }
    }

    /// Releases every lease and returns the first failure.
    func releaseAll() async -> WebInspectorProxyError? {
        let enabledTargets = Self.sorted(Array(targets.values))
        let pendingAcquisitions = Self.sorted(Array(acquisitions.values))
        targets = [:]
        acquisitions = [:]

        var firstError: WebInspectorProxyError?
        for target in enabledTargets {
            if let error = await domainEnablement.releaseStyleAccess(on: target), firstError == nil {
                firstError = error
            }
        }
        for acquisition in pendingAcquisitions {
            do {
                try await acquisition.task.value
                if let error = await domainEnablement.releaseStyleAccess(on: acquisition.target), firstError == nil {
                    firstError = error
                }
            } catch {
                // No release is valid here: a failed registry acquisition
                // never creates a lease.
            }
        }
        return firstError
    }

    func cancelPendingAcquisitions() {
        for acquisition in acquisitions.values {
            acquisition.task.cancel()
        }
    }

    private static func sorted(_ targets: [WebInspectorTarget]) -> [WebInspectorTarget] {
        targets.sorted { sortKey($0) < sortKey($1) }
    }

    private static func sorted(_ acquisitions: [Acquisition]) -> [Acquisition] {
        acquisitions.sorted { sortKey($0.target) < sortKey($1.target) }
    }

    private static func sortKey(_ target: WebInspectorTarget) -> String {
        "\(target.id.rawValue)\u{0}\(target.pageBindingID ?? "")"
    }
}
