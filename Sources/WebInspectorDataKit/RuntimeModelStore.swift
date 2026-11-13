import Foundation
import WebInspectorProxyKit

/// Runtime execution contexts and remote-object registrations for one
/// `WebInspectorContext`.
///
/// The store holds state only. The owning context sends Runtime commands and
/// passes its current page when a decision depends on it. Calls must come from
/// the context's actor.
final class RuntimeModelStore {
    enum ObjectOwner: Hashable {
        case client
        case console
    }

    /// Runtime execution contexts in arrival order.
    private(set) var executionContexts: [RuntimeContext] = [] {
        didSet {
            #if DEBUG
            stateDidChangeForTesting?()
            #endif
        }
    }

    /// The selected Runtime execution context.
    private(set) var selectedContext: RuntimeContext? {
        didSet {
            #if DEBUG
            stateDidChangeForTesting?()
            #endif
        }
    }

    #if DEBUG
    var stateDidChangeForTesting: (() -> Void)?
    #endif

    private var contextsByID: [RuntimeContext.ID: RuntimeContext] = [:]
    private var orderedContextIDs: [RuntimeContext.ID] = []
    private var objectsByID: [RuntimeObject.ID: RuntimeObject] = [:]
    private var objectIDsByProxyID: [Runtime.RemoteObject.ID: RuntimeObject.ID] = [:]
    private var objectOwnersByID: [RuntimeObject.ID: Set<ObjectOwner>] = [:]
    private var nextObjectOrdinal = 0
    private var targetRevisionsByID: [WebInspectorTarget.ID: UInt64] = [:]

    // MARK: - Authority

    /// Maps the identifiers WebKit uses for the current page to the page's
    /// target identifier, so one page has one Runtime authority.
    static func authorityTargetID(
        for targetID: WebInspectorTarget.ID,
        page: WebInspectorTarget?
    ) -> WebInspectorTarget.ID {
        guard let page else {
            return targetID
        }
        if targetID == .currentPage
            || targetID == page.id
            || page.pageBindingID == targetID.rawValue {
            return page.id
        }
        return targetID
    }

    func targetRevision(for targetID: WebInspectorTarget.ID) -> UInt64 {
        targetRevisionsByID[targetID] ?? 0
    }

    /// The authority for objects that arrive without an execution context,
    /// such as Console message parameters.
    func contextlessAuthority(
        forWireTargetID wireTargetID: WebInspectorTarget.ID,
        page: WebInspectorTarget?,
        pageGeneration: Int
    ) -> RuntimeObject.Authority {
        let targetID = Self.authorityTargetID(for: wireTargetID, page: page)
        let frameIDs = Set(contextsByID.values.compactMap { context in
            context.authority.targetID == targetID ? context.frameID : nil
        })
        let frameID = targetID == page?.id || frameIDs.count != 1
            ? nil
            : frameIDs.first
        return RuntimeObject.Authority(
            pageGeneration: pageGeneration,
            targetID: targetID,
            targetRevision: targetRevision(for: targetID),
            context: nil,
            frameID: frameID
        )
    }

    /// Throws unless `authority`, and `object` when given, still describe
    /// registered state for `pageGeneration`.
    func validate(
        _ authority: RuntimeObject.Authority,
        object: RuntimeObject? = nil,
        pageGeneration: Int
    ) throws {
        try Task.checkCancellation()
        guard authority.pageGeneration == pageGeneration,
              authority.targetRevision == targetRevision(for: authority.targetID) else {
            throw Self.staleResultError
        }
        if let contextAuthority = authority.context {
            guard let context = contextsByID[contextAuthority.id],
                  ObjectIdentifier(context) == contextAuthority.identity else {
                throw Self.staleResultError
            }
        }
        if let object {
            guard objectsByID[object.id] === object,
                  object.authority == authority else {
                throw Self.staleResultError
            }
        }
    }

    static var staleResultError: WebInspectorProxyError {
        .disconnected("Runtime command result is no longer current.")
    }

    // MARK: - Execution contexts

    func isRegistered(_ context: RuntimeContext) -> Bool {
        contextsByID[context.id] === context
    }

    /// Selects `context`. A context that is not registered here is ignored.
    func select(_ context: RuntimeContext?) {
        guard let context else {
            selectedContext = nil
            return
        }
        guard isRegistered(context) else {
            return
        }
        selectedContext = context
    }

    func apply(
        _ event: Runtime.Event,
        targetID: WebInspectorTarget.ID?,
        page: WebInspectorTarget?,
        modelContext: WebInspectorContext
    ) {
        switch event {
        case let .executionContextCreated(context):
            applyExecutionContextCreated(
                context,
                eventTargetID: targetID,
                page: page,
                modelContext: modelContext
            )
        case let .executionContextDestroyed(id):
            applyExecutionContextDestroyed(id)
        case let .executionContextsCleared(eventTargetID):
            let resolvedTargetID = Self.authorityTargetID(for: eventTargetID, page: page)
            if resolvedTargetID == page?.id {
                clearExecutionContexts(page: page)
            } else {
                clearExecutionContexts(targetID: resolvedTargetID)
            }
        case .unknown:
            break
        }
    }

    /// Removes every execution context and remote object.
    func clearExecutionContexts(page: WebInspectorTarget?) {
        let targetIDs = Set(contextsByID.values.map { $0.authority.targetID })
            .union(objectsByID.values.map { $0.authority.targetID })
            .union(page.map { [$0.id] } ?? [])
        for targetID in targetIDs {
            advanceTargetRevision(for: targetID)
        }
        contextsByID = [:]
        orderedContextIDs = []
        executionContexts = []
        selectedContext = nil
        removeAllObjects()
    }

    func clearExecutionContexts(targetID: WebInspectorTarget.ID) {
        advanceTargetRevision(for: targetID)
        let removedIDs = Set(contextsByID.compactMap { id, context in
            context.authority.targetID == targetID ? id : nil
        })
        removeContexts(ids: removedIDs)
        removeObjects { authority in
            authority.targetID == targetID
        }
    }

    func clearExecutionContexts(frameID: FrameID, page: WebInspectorTarget?) {
        let frameTargetIDs = Set<WebInspectorTarget.ID>(contextsByID.values.compactMap { context in
            guard context.frameID == frameID,
                  context.authority.targetID != page?.id else {
                return nil
            }
            return context.authority.targetID
        })
        for targetID in frameTargetIDs {
            clearExecutionContexts(targetID: targetID)
        }

        let removedContexts = contextsByID.values.filter {
            $0.frameID == frameID
        }
        let removedIDs = Set(removedContexts.map(\.id))
        removeContexts(ids: removedIDs)
        let removedContextIdentities = Set(removedContexts.map(ObjectIdentifier.init))
        removeObjects { authority in
            authority.frameID == frameID
                || authority.context.map { removedContextIdentities.contains($0.identity) } == true
        }
    }

    private func applyExecutionContextCreated(
        _ payload: Runtime.ExecutionContext,
        eventTargetID: WebInspectorTarget.ID?,
        page: WebInspectorTarget?,
        modelContext: WebInspectorContext
    ) {
        let id = RuntimeContext.ID(payload.id)
        let wireTargetID = payload.id.targetScopeRawValue.map(WebInspectorTarget.ID.init)
            ?? eventTargetID
            ?? .currentPage
        let resolvedTargetID = Self.authorityTargetID(for: wireTargetID, page: page)
        if payload.kind == .normal,
           payload.frameID != nil,
           resolvedTargetID != page?.id,
           contextsByID.values.contains(where: { context in
               context.id != id
                   && context.authority.targetID == resolvedTargetID
                   && context.kind == .normal
           }) {
            clearExecutionContexts(targetID: resolvedTargetID)
        }

        if let context = contextsByID[id] {
            context.update(from: payload)
        } else {
            let context = RuntimeContext(
                context: payload,
                targetID: resolvedTargetID,
                targetRevision: targetRevision(for: resolvedTargetID),
                modelContext: modelContext
            )
            contextsByID[id] = context
            orderedContextIDs.append(id)
        }
        refreshExecutionContexts()
        if selectedContext == nil {
            selectedContext = contextsByID[id]
        }
    }

    private func applyExecutionContextDestroyed(_ proxyID: Runtime.ExecutionContext.ID) {
        let id = RuntimeContext.ID(proxyID)
        guard let removed = contextsByID[id] else {
            WebInspectorDataKitLog.debug(
                "event skipped: Runtime.executionContextDestroyed referenced an untracked context"
            )
            return
        }
        let removedIdentity = ObjectIdentifier(removed)
        removeContexts(ids: [id])
        removeObjects { authority in
            authority.context?.identity == removedIdentity
        }
    }

    private func removeContexts(ids: Set<RuntimeContext.ID>) {
        guard ids.isEmpty == false else {
            return
        }
        let selectedWasRemoved = selectedContext.map { ids.contains($0.id) } ?? false
        for id in ids {
            contextsByID[id] = nil
        }
        orderedContextIDs.removeAll { ids.contains($0) }
        refreshExecutionContexts()
        if selectedWasRemoved {
            selectedContext = executionContexts.first
        }
    }

    private func refreshExecutionContexts() {
        executionContexts = orderedContextIDs.compactMap { contextsByID[$0] }
    }

    private func advanceTargetRevision(for targetID: WebInspectorTarget.ID) {
        targetRevisionsByID[targetID, default: 0] += 1
    }

    // MARK: - Remote objects

    func object(for id: RuntimeObject.ID) -> RuntimeObject? {
        objectsByID[id]
    }

    func isRegistered(_ object: RuntimeObject) -> Bool {
        objectsByID[object.id] === object
    }

    /// Registers `payload`, or updates the registered object that shares its
    /// remote identifier when the two authorities agree.
    func registerObject(
        _ payload: Runtime.RemoteObject,
        owner: ObjectOwner,
        authority: RuntimeObject.Authority,
        modelContext: WebInspectorContext
    ) -> RuntimeObject {
        if let proxyID = payload.id,
           let id = objectIDsByProxyID[proxyID],
           let object = objectsByID[id] {
            if let mergedAuthority = object.authority.merging(authority) {
                object.update(from: payload)
                object.authority = mergedAuthority
                objectOwnersByID[id, default: []].insert(owner)
                return object
            }
            removeObject(id: id, object: object)
        }

        let id: RuntimeObject.ID
        if let proxyID = payload.id {
            id = RuntimeObject.ID(remote: proxyID)
            objectIDsByProxyID[proxyID] = id
        } else {
            id = RuntimeObject.ID(synthetic: nextObjectOrdinal)
            nextObjectOrdinal += 1
        }

        let object = RuntimeObject(
            id: id,
            remoteObject: payload,
            authority: authority,
            modelContext: modelContext
        )
        objectsByID[id] = object
        objectOwnersByID[id] = [owner]
        return object
    }

    /// Drops `owner` from every object and removes objects left without one.
    func unregisterObjects(owner: ObjectOwner) {
        for (id, owners) in objectOwnersByID.map({ ($0.key, $0.value) }) {
            var remainingOwners = owners
            remainingOwners.remove(owner)
            guard remainingOwners.isEmpty else {
                objectOwnersByID[id] = remainingOwners
                continue
            }
            objectOwnersByID.removeValue(forKey: id)
            if let object = objectsByID[id] {
                removeObject(id: id, object: object)
            }
        }
    }

    func unregisterObject(_ object: RuntimeObject, owner: ObjectOwner) {
        guard var owners = objectOwnersByID[object.id] else {
            return
        }
        owners.remove(owner)
        guard owners.isEmpty else {
            objectOwnersByID[object.id] = owners
            return
        }
        objectOwnersByID.removeValue(forKey: object.id)
        removeObject(id: object.id, object: object)
    }

    private func removeAllObjects() {
        let objects = objectsByID
        for (id, object) in objects {
            removeObject(id: id, object: object)
        }
        objectIDsByProxyID = [:]
        objectOwnersByID = [:]
        nextObjectOrdinal = 0
    }

    private func removeObjects(
        where shouldRemove: (RuntimeObject.Authority) -> Bool
    ) {
        let removedObjects = objectsByID.compactMap { id, object in
            shouldRemove(object.authority) ? (id, object) : nil
        }
        for (id, object) in removedObjects {
            removeObject(id: id, object: object)
        }
    }

    private func removeObject(id: RuntimeObject.ID, object: RuntimeObject) {
        let proxyID = object.proxyID
        objectsByID[id] = nil
        objectOwnersByID[id] = nil
        object.invalidateRemoteHandle()
        if let proxyID,
           objectIDsByProxyID[proxyID] == id {
            objectIDsByProxyID.removeValue(forKey: proxyID)
        }
    }
}
