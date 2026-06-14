import Foundation

private struct RuntimeContextAgentState: Sendable {
    var targetID: ProtocolTarget.ID
    var contextsByID: [RuntimeContext.ID: RuntimeContext.Record] = [:]

    var isEmpty: Bool {
        contextsByID.isEmpty
    }
}

package struct RuntimeContextRegistry: Sendable {
    private var agentStatesByID: [ProtocolTarget.ID: RuntimeContextAgentState] = [:]

    package init() {}

    package var contextsByKey: [RuntimeContext.Key: RuntimeContext.Record] {
        Dictionary(
            uniqueKeysWithValues: agentStatesByID.values.flatMap { state in
                state.contextsByID.values.map { ($0.key, $0) }
            }
        )
    }

    package func targetID(for key: RuntimeContext.Key) -> ProtocolTarget.ID? {
        agentStatesByID[key.runtimeAgentTargetID]?.contextsByID[key.contextID]?.targetID
    }

    package mutating func record(_ context: RuntimeContext.Record) {
        var state = agentState(for: context.runtimeAgentTargetID)
        state.contextsByID[context.id] = context
        store(state)
    }

    package mutating func remove(_ key: RuntimeContext.Key) {
        guard var state = agentStatesByID[key.runtimeAgentTargetID] else {
            return
        }
        state.contextsByID.removeValue(forKey: key.contextID)
        store(state)
    }

    package mutating func clear(runtimeAgentTargetID: ProtocolTarget.ID) {
        guard var state = agentStatesByID[runtimeAgentTargetID] else {
            return
        }
        state.contextsByID.removeAll()
        store(state)
    }

    package mutating func removeContexts(targetID: ProtocolTarget.ID) {
        for agentID in Array(agentStatesByID.keys) {
            guard var state = agentStatesByID[agentID] else {
                continue
            }
            state.contextsByID = state.contextsByID.filter { $0.value.targetID != targetID }
            store(state)
        }
    }

    package mutating func removeTarget(_ targetID: ProtocolTarget.ID) {
        agentStatesByID.removeValue(forKey: targetID)
        removeContexts(targetID: targetID)
    }

    package mutating func retarget(oldTargetID: ProtocolTarget.ID, newTargetID: ProtocolTarget.ID) {
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

    private func agentState(for targetID: ProtocolTarget.ID) -> RuntimeContextAgentState {
        agentStatesByID[targetID] ?? RuntimeContextAgentState(targetID: targetID)
    }

    private mutating func store(_ state: RuntimeContextAgentState) {
        if state.isEmpty {
            agentStatesByID.removeValue(forKey: state.targetID)
        } else {
            agentStatesByID[state.targetID] = state
        }
    }

    private mutating func replace(with contextsByKey: [RuntimeContext.Key: RuntimeContext.Record]) {
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
