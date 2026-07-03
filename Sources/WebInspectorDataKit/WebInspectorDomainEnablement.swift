import Foundation
import WebInspectorProxyKit

enum WebInspectorEnabledDomain: Hashable, Sendable {
    case console
    case network
    case runtime

    var rawValue: String {
        switch self {
        case .console:
            return "Console"
        case .network:
            return "Network"
        case .runtime:
            return "Runtime"
        }
    }

    fileprivate func enable(on target: WebInspectorTarget) async throws {
        switch self {
        case .console:
            try await target.console.enable()
        case .network:
            try await target.network.enable()
        case .runtime:
            try await target.runtime.enable()
        }
    }

    fileprivate func disable(on target: WebInspectorTarget) async throws {
        switch self {
        case .console:
            try await target.console.disable()
        case .network:
            try await target.network.disable()
        case .runtime:
            try await target.runtime.disable()
        }
    }

    fileprivate func commandFailed(method: String, error: any Error) -> WebInspectorProxyError {
        .commandFailed(
            domain: rawValue,
            method: method,
            message: String(describing: error)
        )
    }
}

private struct WebInspectorDomainEnablementKey: Hashable, Sendable {
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorEnabledDomain
}

actor WebInspectorDomainEnablementRegistry {
    private enum Entry: Sendable {
        case enabling(count: Int, generation: Int, task: Task<Void, any Error>)
        case enabled(count: Int)
    }

    private var entries: [WebInspectorDomainEnablementKey: Entry]
    private var nextGeneration: Int

    init() {
        entries = [:]
        nextGeneration = 0
    }

    func acquire(_ domain: WebInspectorEnabledDomain, on target: WebInspectorTarget) async throws {
        let key = WebInspectorDomainEnablementKey(targetID: target.id, domain: domain)

        switch entries[key] {
        case let .enabled(count):
            entries[key] = .enabled(count: count + 1)
            WebInspectorDataKitLog.debug(
                "domain acquire shared domain=\(domain.rawValue) target=\(target.id.rawValue) count=\(count + 1)"
            )
            return
        case let .enabling(count, generation, task):
            entries[key] = .enabling(count: count + 1, generation: generation, task: task)
            WebInspectorDataKitLog.debug(
                "domain acquire pending domain=\(domain.rawValue) target=\(target.id.rawValue) count=\(count + 1)"
            )
            try await finishEnabling(key: key, domain: domain, generation: generation, task: task)
        case nil:
            let generation = nextGeneration
            nextGeneration += 1
            let task = Task<Void, any Error> {
                try await domain.enable(on: target)
            }
            entries[key] = .enabling(count: 1, generation: generation, task: task)
            WebInspectorDataKitLog.debug("domain enable start domain=\(domain.rawValue) target=\(target.id.rawValue)")
            try await finishEnabling(key: key, domain: domain, generation: generation, task: task)
        }
    }

    func release(_ domain: WebInspectorEnabledDomain, on target: WebInspectorTarget) async -> WebInspectorProxyError? {
        let key = WebInspectorDomainEnablementKey(targetID: target.id, domain: domain)

        switch entries[key] {
        case let .enabled(count):
            precondition(count > 0, "WebInspector domain enablement count must be positive.")
            if count > 1 {
                entries[key] = .enabled(count: count - 1)
                WebInspectorDataKitLog.debug(
                    "domain release shared domain=\(domain.rawValue) target=\(target.id.rawValue) count=\(count - 1)"
                )
                return nil
            }
            entries[key] = nil
            WebInspectorDataKitLog.debug("domain disable start domain=\(domain.rawValue) target=\(target.id.rawValue)")
            return await disable(domain, on: target)
        case let .enabling(count, generation, task):
            precondition(count > 0, "WebInspector domain enablement count must be positive.")
            if count > 1 {
                entries[key] = .enabling(count: count - 1, generation: generation, task: task)
                WebInspectorDataKitLog.debug(
                    "domain release pending domain=\(domain.rawValue) target=\(target.id.rawValue) count=\(count - 1)"
                )
            } else {
                entries[key] = nil
                WebInspectorDataKitLog.debug("domain release pending cancelled domain=\(domain.rawValue) target=\(target.id.rawValue)")
                return await disableAfterPendingEnable(domain, on: target, task: task)
            }
            return nil
        case nil:
            preconditionFailure("Releasing WebInspector domain enablement without a matching acquire.")
        }
    }

    private func finishEnabling(
        key: WebInspectorDomainEnablementKey,
        domain: WebInspectorEnabledDomain,
        generation: Int,
        task: Task<Void, any Error>
    ) async throws {
        do {
            try await task.value
            if case let .enabling(count, currentGeneration, _) = entries[key],
               currentGeneration == generation {
                entries[key] = .enabled(count: count)
                WebInspectorDataKitLog.debug(
                    "domain enable finished domain=\(domain.rawValue) target=\(key.targetID.rawValue) count=\(count)"
                )
            }
        } catch {
            if case let .enabling(_, currentGeneration, _) = entries[key],
               currentGeneration == generation {
                entries[key] = nil
            }
            WebInspectorDataKitLog.debug(
                "domain enable failed domain=\(domain.rawValue) target=\(key.targetID.rawValue) error=\(String(describing: error))"
            )
            if let error = error as? WebInspectorProxyError {
                throw error
            }
            throw domain.commandFailed(method: "enable", error: error)
        }
    }

    private func disable(_ domain: WebInspectorEnabledDomain, on target: WebInspectorTarget) async -> WebInspectorProxyError? {
        do {
            try await domain.disable(on: target)
            WebInspectorDataKitLog.debug("domain disable finished domain=\(domain.rawValue) target=\(target.id.rawValue)")
            return nil
        } catch WebInspectorProxyError.closed {
            WebInspectorDataKitLog.debug("domain disable skipped closed domain=\(domain.rawValue) target=\(target.id.rawValue)")
            return nil
        } catch WebInspectorProxyError.disconnected(_) {
            WebInspectorDataKitLog.debug("domain disable skipped disconnected domain=\(domain.rawValue) target=\(target.id.rawValue)")
            return nil
        } catch let error as WebInspectorProxyError {
            WebInspectorDataKitLog.debug(
                "domain disable failed domain=\(domain.rawValue) target=\(target.id.rawValue) error=\(String(describing: error))"
            )
            return error
        } catch {
            WebInspectorDataKitLog.debug(
                "domain disable failed domain=\(domain.rawValue) target=\(target.id.rawValue) error=\(String(describing: error))"
            )
            return domain.commandFailed(method: "disable", error: error)
        }
    }

    private func disableAfterPendingEnable(
        _ domain: WebInspectorEnabledDomain,
        on target: WebInspectorTarget,
        task: Task<Void, any Error>
    ) async -> WebInspectorProxyError? {
        do {
            try await task.value
        } catch {
            WebInspectorDataKitLog.debug(
                "domain release pending skipped disable domain=\(domain.rawValue) target=\(target.id.rawValue) error=\(String(describing: error))"
            )
            return nil
        }
        return await disable(domain, on: target)
    }
}
