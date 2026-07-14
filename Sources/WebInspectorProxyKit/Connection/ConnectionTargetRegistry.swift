import Foundation

package struct ConnectionTargetRegistry: Sendable {
    package private(set) var records: [ProtocolTarget.ID: ProtocolTarget.Record] = [:]
    package private(set) var targetByFrame: [ProtocolFrame.ID: ProtocolTarget.ID] = [:]
    package private(set) var currentPageID: ProtocolTarget.ID?

    package init() {}

    package var currentPage: ProtocolTarget.Record? {
        currentPageID.flatMap { records[$0] }
    }

    package func record(for id: ProtocolTarget.ID) -> ProtocolTarget.Record? {
        records[id]
    }

    @discardableResult
    package mutating func insert(_ record: ProtocolTarget.Record) -> Bool {
        let hadCurrentPage = currentPageID != nil
        records[record.id] = record
        if let frameID = record.frameID {
            targetByFrame[frameID] = record.id
        }
        if currentPageID == nil, record.isTopLevelPage, !record.isProvisional {
            currentPageID = record.id
        }
        return !hadCurrentPage && currentPageID != nil
    }

    @discardableResult
    package mutating func remove(_ id: ProtocolTarget.ID) -> Bool {
        let removedCurrentPage = currentPageID == id
        records.removeValue(forKey: id)
        targetByFrame = targetByFrame.filter { $0.value != id }
        if removedCurrentPage {
            currentPageID = nil
        }
        return removedCurrentPage
    }

    @discardableResult
    package mutating func commit(
        old oldID: ProtocolTarget.ID,
        new newID: ProtocolTarget.ID
    ) -> Bool {
        let replacingCurrentPage = currentPageID == oldID
        let oldRecord = records.removeValue(forKey: oldID)
        guard var newRecord = records[newID] ?? oldRecord else {
            return false
        }

        newRecord.id = newID
        newRecord.frameID = newRecord.frameID ?? oldRecord?.frameID
        newRecord.parentFrameID = newRecord.parentFrameID ?? oldRecord?.parentFrameID
        newRecord.isProvisional = false
        records[newID] = newRecord
        targetByFrame = targetByFrame.filter { $0.value != oldID }
        if let frameID = newRecord.frameID {
            targetByFrame[frameID] = newID
        }
        if replacingCurrentPage, newRecord.isTopLevelPage {
            currentPageID = newID
        } else if currentPageID == nil, newRecord.isTopLevelPage {
            currentPageID = newID
        }
        return replacingCurrentPage
    }

    package func resolve(_ route: WebInspectorRoute) -> ProtocolTarget.ID? {
        switch route {
        case .root:
            nil
        case .currentPage:
            currentPageID
        case let .target(id):
            ProtocolTarget.ID(id.rawValue)
        }
    }

    package func selectedTargets(
        for policy: WebInspectorTargetSelectionPolicy
    ) -> Set<ProtocolTarget.ID> {
        guard let anchorID = resolve(anchor: policy.anchor),
              let anchor = records[anchorID] else {
            return []
        }
        var selected: Set<ProtocolTarget.ID> = policy.includesAnchor ? [anchorID] : []
        guard !policy.descendantKinds.isEmpty else { return selected }

        for record in records.values where policy.descendantKinds.contains(record.kind) {
            if isDescendant(record, of: anchor) {
                selected.insert(record.id)
            }
        }
        return selected
    }

    package func targetScopeRawValue(for id: ProtocolTarget.ID?) -> String? {
        guard let id else { return nil }
        if id == currentPageID { return nil }
        if records[id]?.isTopLevelPage == true { return nil }
        return id.rawValue
    }

    package func target(
        for id: ProtocolTarget.ID?,
        identity: WebInspectorTarget.ID? = nil
    ) -> WebInspectorTarget? {
        guard let id, let record = records[id] else { return nil }
        return WebInspectorTarget(
            id: identity ?? WebInspectorTarget.ID(id.rawValue),
            kind: record.kind,
            frameID: record.frameID.map { FrameID($0.rawValue) },
            isProvisional: record.isProvisional
        )
    }

    package func semanticTarget(
        for selection: WebInspectorTargetSelectionPolicy
    ) -> WebInspectorTarget? {
        switch selection.anchor {
        case .currentPage:
            return target(for: currentPageID, identity: .currentPage)
        case let .target(id):
            return target(for: ProtocolTarget.ID(id.rawValue), identity: id)
        }
    }

    private func resolve(anchor: WebInspectorTargetSelectionPolicy.Anchor) -> ProtocolTarget.ID? {
        switch anchor {
        case .currentPage:
            currentPageID
        case let .target(id):
            ProtocolTarget.ID(id.rawValue)
        }
    }

    private func isDescendant(
        _ candidate: ProtocolTarget.Record,
        of anchor: ProtocolTarget.Record
    ) -> Bool {
        guard candidate.id != anchor.id else { return false }
        if candidate.frameID == anchor.frameID, anchor.frameID != nil { return true }
        if candidate.parentFrameID == anchor.frameID, anchor.frameID != nil { return true }
        guard var parentFrameID = candidate.parentFrameID else { return false }
        var visited: Set<ProtocolFrame.ID> = []
        while visited.insert(parentFrameID).inserted {
            if parentFrameID == anchor.frameID { return true }
            guard let parentTargetID = targetByFrame[parentFrameID],
                  let parent = records[parentTargetID],
                  let next = parent.parentFrameID else {
                return false
            }
            parentFrameID = next
        }
        return false
    }
}
