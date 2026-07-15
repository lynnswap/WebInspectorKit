import Foundation

package struct ConnectionTargetRegistry: Sendable {
    package struct CommitMutation: Sendable {
        package let bindingChanged: Bool
        package let retiredTargetID: ProtocolTarget.ID?
        package let committedTargetID: ProtocolTarget.ID?
    }

    package private(set) var records: [ProtocolTarget.ID: ProtocolTarget.Record] = [:]
    package private(set) var currentPageID: ProtocolTarget.ID?

    package init() {}

    package var currentPage: ProtocolTarget.Record? {
        currentPageID.flatMap { records[$0] }
    }

    package func record(for id: ProtocolTarget.ID) -> ProtocolTarget.Record? {
        records[id]
    }

    package func targetKind(
        protocolType: String,
        parentTargetID: ProtocolTarget.ID?
    ) -> ProtocolTarget.Kind {
        let protocolKind = ProtocolTarget.Kind(protocolType: protocolType)
        guard protocolKind == .page else { return protocolKind }
        if parentTargetID != nil { return .frame }
        return .page
    }

    @discardableResult
    package mutating func insert(_ record: ProtocolTarget.Record) -> Bool {
        let hadCurrentPage = currentPageID != nil
        records[record.id] = record
        if currentPageID == nil, record.isTopLevelPage, !record.isProvisional {
            currentPageID = record.id
        }
        return !hadCurrentPage && currentPageID != nil
    }

    @discardableResult
    package mutating func remove(_ id: ProtocolTarget.ID) -> Bool {
        let removedCurrentPage = currentPageID == id
        records.removeValue(forKey: id)
        if removedCurrentPage {
            currentPageID = nil
        }
        return removedCurrentPage
    }

    @discardableResult
    package mutating func commit(
        old oldID: ProtocolTarget.ID,
        new newID: ProtocolTarget.ID
    ) -> CommitMutation {
        let previousCurrentPageID = currentPageID
        let replacingCurrentPage = currentPageID == oldID
        let oldRecord = records.removeValue(forKey: oldID)
        guard var newRecord = records[newID] ?? oldRecord else {
            return CommitMutation(
                bindingChanged: false,
                retiredTargetID: nil,
                committedTargetID: nil
            )
        }

        newRecord.id = newID
        newRecord.parentTargetID = newRecord.parentTargetID ?? oldRecord?.parentTargetID
        newRecord.isProvisional = false
        records[newID] = newRecord
        if replacingCurrentPage, newRecord.isTopLevelPage {
            currentPageID = newID
        } else if currentPageID == nil, newRecord.isTopLevelPage {
            currentPageID = newID
        }
        return CommitMutation(
            bindingChanged: previousCurrentPageID != currentPageID,
            retiredTargetID: oldID,
            committedTargetID: newID
        )
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
              let anchor = records[anchorID],
              !anchor.isProvisional else {
            return []
        }
        var selected: Set<ProtocolTarget.ID> = policy.includesAnchor ? [anchorID] : []
        guard !policy.descendantKinds.isEmpty else { return selected }

        for record in records.values where
            !record.isProvisional && policy.descendantKinds.contains(record.kind)
        {
            let isSelectedDescendant = if anchorID == currentPageID {
                belongsToCurrentPage(record)
            } else {
                isDescendant(record, of: anchor)
            }
            if isSelectedDescendant {
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
            frameID: record.frameID,
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
        guard var parentTargetID = candidate.parentTargetID else { return false }
        var visited: Set<ProtocolTarget.ID> = []
        while visited.insert(parentTargetID).inserted {
            if parentTargetID == anchor.id { return true }
            guard let parent = records[parentTargetID],
                  !parent.isProvisional,
                  let next = parent.parentTargetID else {
                return false
            }
            parentTargetID = next
        }
        return false
    }

    private func belongsToCurrentPage(
        _ candidate: ProtocolTarget.Record
    ) -> Bool {
        guard candidate.id != currentPageID else { return false }
        if candidate.kind == .frame { return true }
        guard var parentTargetID = candidate.parentTargetID else { return false }
        var visited: Set<ProtocolTarget.ID> = []
        while visited.insert(parentTargetID).inserted {
            if parentTargetID == currentPageID { return true }
            guard let parent = records[parentTargetID], !parent.isProvisional else {
                return false
            }
            if parent.kind == .frame { return true }
            guard let next = parent.parentTargetID else { return false }
            parentTargetID = next
        }
        return false
    }
}
