import Foundation

private struct RuntimeContextAgentState: Sendable {
    var targetID: ProtocolTargetIdentifier
    var contextsByID: [ExecutionContextID: RuntimeExecutionContextRecord] = [:]

    var isEmpty: Bool {
        contextsByID.isEmpty
    }
}

package struct RuntimeContextRegistry: Sendable {
    private var agentStatesByID: [ProtocolTargetIdentifier: RuntimeContextAgentState] = [:]

    package init() {}

    package var contextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord] {
        Dictionary(
            uniqueKeysWithValues: agentStatesByID.values.flatMap { state in
                state.contextsByID.values.map { ($0.key, $0) }
            }
        )
    }

    package func targetID(for key: RuntimeExecutionContextKey) -> ProtocolTargetIdentifier? {
        agentStatesByID[key.runtimeAgentTargetID]?.contextsByID[key.contextID]?.targetID
    }

    package mutating func record(_ context: RuntimeExecutionContextRecord) {
        var state = agentState(for: context.runtimeAgentTargetID)
        state.contextsByID[context.id] = context
        store(state)
    }

    package mutating func remove(_ key: RuntimeExecutionContextKey) {
        guard var state = agentStatesByID[key.runtimeAgentTargetID] else {
            return
        }
        state.contextsByID.removeValue(forKey: key.contextID)
        store(state)
    }

    package mutating func clear(runtimeAgentTargetID: ProtocolTargetIdentifier) {
        guard var state = agentStatesByID[runtimeAgentTargetID] else {
            return
        }
        state.contextsByID.removeAll()
        store(state)
    }

    package mutating func removeContexts(targetID: ProtocolTargetIdentifier) {
        for agentID in Array(agentStatesByID.keys) {
            guard var state = agentStatesByID[agentID] else {
                continue
            }
            state.contextsByID = state.contextsByID.filter { $0.value.targetID != targetID }
            store(state)
        }
    }

    package mutating func removeTarget(_ targetID: ProtocolTargetIdentifier) {
        agentStatesByID.removeValue(forKey: targetID)
        removeContexts(targetID: targetID)
    }

    package mutating func retarget(oldTargetID: ProtocolTargetIdentifier, newTargetID: ProtocolTargetIdentifier) {
        let currentContexts = contextsByKey
        var nextContexts = currentContexts
        for (contextKey, context) in currentContexts {
            var movedContext = context
            if movedContext.targetID == oldTargetID {
                movedContext.targetID = newTargetID
            }
            if movedContext.runtimeAgentTargetID == oldTargetID {
                movedContext.runtimeAgentTargetID = newTargetID
            }
            guard movedContext != context else {
                continue
            }
            nextContexts.removeValue(forKey: contextKey)
            if nextContexts[movedContext.key] == nil {
                nextContexts[movedContext.key] = movedContext
            }
        }
        replace(with: nextContexts)
    }

    private func agentState(for targetID: ProtocolTargetIdentifier) -> RuntimeContextAgentState {
        agentStatesByID[targetID] ?? RuntimeContextAgentState(targetID: targetID)
    }

    private mutating func store(_ state: RuntimeContextAgentState) {
        if state.isEmpty {
            agentStatesByID.removeValue(forKey: state.targetID)
        } else {
            agentStatesByID[state.targetID] = state
        }
    }

    private mutating func replace(with contextsByKey: [RuntimeExecutionContextKey: RuntimeExecutionContextRecord]) {
        for agentID in agentStatesByID.keys {
            agentStatesByID[agentID]?.contextsByID.removeAll()
        }
        for context in contextsByKey.values {
            record(context)
        }
        for agentID in Array(agentStatesByID.keys) {
            if let state = agentStatesByID[agentID] {
                store(state)
            }
        }
    }
}
