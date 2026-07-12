import Foundation
import Observation
import WebInspectorProxyKit

/// Pre-edit snapshot of a property row, recorded the first time the
/// inspector rewrites its declaration. A property is "modified by
/// inspector" while its current state differs from this baseline.
private struct CSSPropertyInspectorBaseline: Equatable {
    var styleID: CSS.Style.ID
    var name: String
    var value: String
    var priority: String?
    var text: String?
    var status: CSS.Status

    init(styleID: CSS.Style.ID, property: CSS.Property) {
        self.styleID = styleID
        name = property.name
        value = property.value
        priority = property.priority
        text = property.text
        status = property.status
    }
}

private struct InspectorBaselineName: Hashable {
    var styleID: CSS.Style.ID
    var propertyName: String
}

/// Context-owned edit history for backend style declarations. `CSS.Style.ID`
/// already carries the target scope added by ProxyKit, while the current-page
/// scope is retired by document reset. Stylesheet rule IDs are shared by every
/// DOM node matched by that rule, so node-owned `CSSStyles` resources must
/// consult one baseline owner.
final class CSSInspectorBaselineStore {
    private var baselines: [CSSStyleProperty.ID: CSSPropertyInspectorBaseline] = [:]

    func reset() {
        baselines.removeAll()
    }

    func reset(targetID: WebInspectorTarget.ID) {
        baselines = baselines.filter { _, baseline in
            baseline.styleID.targetScopeRawValue != targetID.rawValue
        }
    }

    func recordIfNeeded(
        propertyID: CSSStyleProperty.ID,
        styleID: CSS.Style.ID,
        property: CSS.Property
    ) {
        guard baselines[propertyID] == nil else {
            return
        }
        baselines[propertyID] = CSSPropertyInspectorBaseline(
            styleID: styleID,
            property: property
        )
    }

    func reconcile(
        styleIDs: Set<CSS.Style.ID>,
        incomingSections: [CSSStyleSection]
    ) {
        guard styleIDs.isEmpty == false else {
            return
        }

        let incomingPropertiesByStyleID = cssPropertiesByStyleID(in: incomingSections)
        let baselineNameCounts = Dictionary(
            grouping: baselines.values,
            by: { baseline in
                InspectorBaselineName(
                    styleID: baseline.styleID,
                    propertyName: baseline.name
                )
            }
        ).mapValues(\.count)
        var reconciledBaselines: [CSSStyleProperty.ID: CSSPropertyInspectorBaseline] = [:]

        for (propertyID, baseline) in baselines {
            guard styleIDs.contains(baseline.styleID) else {
                reconciledBaselines[propertyID] = baseline
                continue
            }
            let name = InspectorBaselineName(
                styleID: baseline.styleID,
                propertyName: baseline.name
            )
            guard baselineNameCounts[name] == 1,
                  let incomingProperties = incomingPropertiesByStyleID[baseline.styleID] else {
                continue
            }
            let matchingProperties = incomingProperties.filter { $0.name == baseline.name }
            guard matchingProperties.count == 1,
                  let incomingProperty = matchingProperties.first else {
                continue
            }
            reconciledBaselines[incomingProperty.id] = baseline
        }
        baselines = reconciledBaselines
    }

    func applyingBaselines(
        to style: CSS.Style,
        clearsRestoredBaselines: Bool = false
    ) -> CSS.Style {
        guard baselines.isEmpty == false else {
            return style
        }
        var style = style
        style.properties = style.properties.map { property in
            let propertyID = CSSStyleProperty.ID(property.id)
            guard let baseline = baselines[propertyID],
                  baseline.name == property.name else {
                return property
            }
            let isModified = CSSPropertyInspectorBaseline(
                styleID: style.id,
                property: property
            ) != baseline
            if isModified == false, clearsRestoredBaselines {
                baselines[propertyID] = nil
            }
            return CSS.Property(
                id: property.id,
                name: property.name,
                value: property.value,
                priority: property.priority,
                text: property.text,
                parsedOk: property.parsedOk,
                status: property.status,
                implicit: property.implicit,
                range: property.range,
                isEditable: property.isEditable,
                isModifiedByInspector: isModified
            )
        }
        return style
    }
}

private func cssPropertiesByStyleID(
    in sections: [CSSStyleSection]
) -> [CSS.Style.ID: [CSSStyleProperty]] {
    var result: [CSS.Style.ID: [CSSStyleProperty]] = [:]
    for section in sections {
        let styleID = section.proxyStyle.id
        if let existing = result[styleID] {
            precondition(
                existing.map(\.name) == section.style.properties.map(\.name),
                "Sections sharing a CSS style must agree on declaration topology."
            )
        } else {
            result[styleID] = section.style.properties
        }
    }
    return result
}

private actor CSSStylesOperationGate {
    private struct Waiter {
        var continuation: CheckedContinuation<Void, any Error>
    }

    private var isAcquired = false
    private var waiters: [UInt64: Waiter] = [:]
    private var waiterOrder: [UInt64] = []
    private var nextWaiterID: UInt64 = 0

    func acquire() async throws {
        try Task.checkCancellation()
        guard isAcquired else {
            isAcquired = true
            return
        }
        precondition(nextWaiterID < UInt64.max, "CSS operation waiter identity overflowed.")
        nextWaiterID += 1
        let waiterID = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[waiterID] = Waiter(continuation: continuation)
                waiterOrder.append(waiterID)
            }
        } onCancel: {
            Task {
                await self.cancel(waiterID: waiterID)
            }
        }
        do {
            try Task.checkCancellation()
        } catch {
            // A release may win the race with the cancellation handler and
            // hand this waiter ownership. Return that ownership before
            // surfacing cancellation so the next waiter cannot deadlock.
            release()
            throw error
        }
    }

    func release() {
        precondition(isAcquired, "CSS operation gate released without an owner.")
        while let waiterID = waiterOrder.first {
            waiterOrder.removeFirst()
            guard let waiter = waiters.removeValue(forKey: waiterID) else {
                continue
            }
            waiter.continuation.resume(returning: ())
            return
        }
        isAcquired = false
    }

    private func cancel(waiterID: UInt64) {
        waiters.removeValue(forKey: waiterID)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

/// Observable CSS state for one DOM element.
@Observable
public final class CSSStyles: Hashable, Identifiable, SendableMetatype {
    /// Stable identity for an element's CSS style model.
    public struct ID: Hashable, Sendable {
        let nodeID: DOMNode.ID

        init(nodeID: DOMNode.ID) {
            self.nodeID = nodeID
        }
    }

    /// Loading phase for element style data.
    public enum Phase: Equatable, Sendable {
        /// CSS information is currently being requested.
        case loading

        /// CSS information has been loaded.
        case loaded

        /// CSS information is stale and should be refreshed.
        case needsRefresh

        /// CSS information is unavailable for the element.
        case unavailable

        /// CSS information failed to load.
        case failed(WebInspectorProxyError)
    }

    struct SetStyleTextIntent {
        let styleID: CSS.Style.ID
        let text: String
    }

    /// The stable style model identity.
    public let id: ID

    /// The current loading phase.
    public private(set) var phase: Phase

    /// Style sections displayed for the element.
    public private(set) var sections: [CSSStyleSection]

    /// Computed properties for the element.
    public private(set) var computedProperties: [CSSComputedProperty]

    @ObservationIgnored weak var modelContext: WebInspectorModelContext?
    @ObservationIgnored private let inspectorBaselineStore: CSSInspectorBaselineStore
    @ObservationIgnored private var hasCompletedLoad: Bool
    @ObservationIgnored private let operationGate = CSSStylesOperationGate()

    init(nodeID: DOMNode.ID, modelContext: WebInspectorModelContext) {
        id = ID(nodeID: nodeID)
        phase = .loading
        sections = []
        computedProperties = []
        inspectorBaselineStore = modelContext.cssInspectorBaselineStore
        hasCompletedLoad = false
        self.modelContext = modelContext
    }

    /// Compares CSS resources by object identity.
    public nonisolated static func == (lhs: CSSStyles, rhs: CSSStyles) -> Bool {
        lhs === rhs
    }

    /// Hashes a CSS resource by object identity.
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func markLoading() {
        phase = .loading
    }

    func load(
        matchedStyles: CSS.MatchedStyles,
        inlineStyles: CSS.InlineStyles,
        computedProperties: [CSS.ComputedProperty]
    ) {
        let rawSections = CSSStyleSectionBuilder.makeSections(matched: matchedStyles, inline: inlineStyles)
        let incomingSections = rawSections
            .map { section($0, replacingStyleWith: inspectorBaselineStore.applyingBaselines(to: $0.proxyStyle)) }
        sections = reconciledSections(incomingSections)
        self.computedProperties = computedProperties.map(CSSComputedProperty.init)
        hasCompletedLoad = true
        phase = .loaded
    }

    func markNeedsRefresh() {
        phase = .needsRefresh
    }

    func markUnavailable() {
        sections = []
        computedProperties = []
        hasCompletedLoad = false
        phase = .unavailable
    }

    func fail(_ error: WebInspectorProxyError) {
        sections = []
        computedProperties = []
        hasCompletedLoad = false
        phase = .failed(error)
    }

    func cancelLoading() {
        phase = hasCompletedLoad ? .needsRefresh : .unavailable
    }

    /// Synchronous validation for a property toggle: returns the backend
    /// command inputs when the property is currently editable, or nil to
    /// refuse the toggle (stale phase, non-editable section/style/property,
    /// no-op toggle, or unrewritable style text).
    func setStyleTextIntent(for property: CSSStyleProperty, enabled: Bool) -> SetStyleTextIntent? {
        guard phase == .loaded,
              let (sectionIndex, propertyIndex) = locateProperty(property) else {
            return nil
        }
        let section = sections[sectionIndex]
        guard section.isEditable else {
            return nil
        }
        let style = section.proxyStyle
        guard style.isEditable else {
            return nil
        }
        let proxyProperty = style.properties[propertyIndex]
        guard proxyProperty.isEditable,
              (proxyProperty.status != .disabled) != enabled,
              let text = CSSStyleTextRewriter.rewrittenStyleText(
                  style: style,
                  propertyIndex: propertyIndex,
                  enabled: enabled
              ) else {
            return nil
        }
        return SetStyleTextIntent(styleID: style.id, text: text)
    }

    func contains(property: CSSStyleProperty) -> Bool {
        sections.contains { section in
            section.style.properties.contains { $0 === property }
        }
    }

    func contains(ruleID: CSSStyleRule.ID) -> Bool {
        sections.contains { $0.rule?.id == ruleID }
    }

    func setDeclarationTextIntent(for property: CSSStyleProperty, text replacementText: String) -> SetStyleTextIntent? {
        guard phase == .loaded,
              let (sectionIndex, propertyIndex) = locateProperty(property) else {
            return nil
        }
        let section = sections[sectionIndex]
        guard section.isEditable else {
            return nil
        }
        let style = section.proxyStyle
        guard style.isEditable else {
            return nil
        }
        let proxyProperty = style.properties[propertyIndex]
        guard proxyProperty.isEditable,
              let text = CSSStyleTextRewriter.rewrittenStyleText(
                  style: style,
                  propertyIndex: propertyIndex,
                  replacementText: replacementText
              ) else {
            return nil
        }
        return SetStyleTextIntent(styleID: style.id, text: text)
    }

    /// Applies a `CSS.setStyleText` result: records the toggled property's
    /// pre-edit baseline, rewrites every section sharing the returned
    /// style's ID (keeping section identity), recomputes
    /// `isModifiedByInspector` against recorded baselines, and marks the
    /// styles stale for the follow-up refresh.
    func applySetStyleText(result: CSS.Style, for propertyID: CSSStyleProperty.ID) {
        var updatedSections = sections
        var didRewriteSection = false
        let mutatedProperty = sections.lazy
            .flatMap(\.style.properties)
            .first { $0.id == propertyID }
        for index in sections.indices where sections[index].proxyStyle.id == result.id {
            let section = sections[index]
            if let property = section.proxyStyle.properties.first(where: { $0.id == propertyID.proxyID }) {
                inspectorBaselineStore.recordIfNeeded(
                    propertyID: propertyID,
                    styleID: section.proxyStyle.id,
                    property: property
                )
            }
            let normalized = CSSStyleSectionBuilder.normalizedStyle(
                result,
                isEditable: section.isEditable,
                ruleOrigin: section.proxyRule?.origin
            )
            updatedSections[index] = self.section(
                section,
                replacingStyleWith: normalized
            )
            didRewriteSection = true
        }
        if didRewriteSection {
            inspectorBaselineStore.reconcile(
                styleIDs: styleIDsWithChangedPropertyTopology(in: updatedSections),
                incomingSections: updatedSections
            )
            let normalizedSections = updatedSections.map {
                section(
                    $0,
                    replacingStyleWith: inspectorBaselineStore.applyingBaselines(
                        to: $0.proxyStyle,
                        clearsRestoredBaselines: true
                    )
                )
            }
            sections = reconciledSections(
                normalizedSections,
                preservingMutationOf: mutatedProperty
            )
            phase = .needsRefresh
        }
    }

    func withExclusiveOperation<Output>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Output
    ) async throws -> Output {
        _ = isolation
        try await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let output = try await operation()
            await operationGate.release()
            return output
        } catch {
            await operationGate.release()
            recoverLoadingPhaseAfterCancellation(error)
            throw error
        }
    }

    private func recoverLoadingPhaseAfterCancellation(_ error: any Error) {
        guard error is CancellationError, phase == .loading else {
            return
        }
        cancelLoading()
    }

    private func locateProperty(_ property: CSSStyleProperty) -> (sectionIndex: Int, propertyIndex: Int)? {
        for sectionIndex in sections.indices {
            guard let propertyIndex = sections[sectionIndex].proxyStyle.properties.firstIndex(
                where: { $0.id == property.id.proxyID }
            ),
                  sections[sectionIndex].style.properties.indices.contains(propertyIndex),
                  sections[sectionIndex].style.properties[propertyIndex] === property else {
                continue
            }
            return (sectionIndex, propertyIndex)
        }
        return nil
    }

    private func section(_ section: CSSStyleSection, replacingStyleWith style: CSS.Style) -> CSSStyleSection {
        var rule = section.proxyRule
        rule?.style = style
        return CSSStyleSection(
            id: section.id,
            kind: section.kind,
            title: section.title,
            rule: rule,
            style: style,
            isEditable: section.isEditable
        )
    }

    private func reconciledSections(
        _ incomingSections: [CSSStyleSection],
        preservingMutationOf mutatedProperty: CSSStyleProperty? = nil
    ) -> [CSSStyleSection] {
        let existingPropertiesByStyleID = propertiesByStyleID(in: sections)
        var reconciledPropertiesByStyleID: [CSS.Style.ID: [CSSStyleProperty]] = [:]
        return incomingSections.map { section in
            let styleID = section.proxyStyle.id
            let properties: [CSSStyleProperty]
            if let reconciled = reconciledPropertiesByStyleID[styleID] {
                properties = reconciled
            } else {
                properties = reconciledProperties(
                    existing: existingPropertiesByStyleID[styleID] ?? [],
                    incoming: section.style.properties,
                    preservingMutationOf: mutatedProperty
                )
                reconciledPropertiesByStyleID[styleID] = properties
            }
            return CSSStyleSection(
                id: section.id,
                kind: section.kind,
                title: section.title,
                rule: section.proxyRule,
                style: section.proxyStyle,
                isEditable: section.isEditable,
                propertyModels: properties
            )
        }
    }

    private func reconciledProperties(
        existing: [CSSStyleProperty],
        incoming: [CSSStyleProperty],
        preservingMutationOf mutatedProperty: CSSStyleProperty?
    ) -> [CSSStyleProperty] {
        guard existing.map(\.name) == incoming.map(\.name) else {
            // Backend property IDs are positional. Once declaration topology
            // changes, no raw ID proves semantic continuity, so every old
            // handle must become stale rather than aliasing a new declaration.
            return incoming
        }

        let nameCounts = Dictionary(grouping: existing, by: \.name).mapValues(\.count)
        return zip(existing, incoming).map { existingProperty, incomingProperty in
            let canPreserveIdentity = nameCounts[existingProperty.name] == 1
                || existingProperty === mutatedProperty
                || hasEqualDeclarationContent(existingProperty, incomingProperty)
            guard canPreserveIdentity else {
                // Duplicate declarations have no protocol identity beyond
                // position. A changed duplicate is ambiguous unless this
                // operation explicitly owns that declaration.
                return incomingProperty
            }
            existingProperty.update(from: incomingProperty)
            return existingProperty
        }
    }

    private func styleIDsWithChangedPropertyTopology(
        in incomingSections: [CSSStyleSection]
    ) -> Set<CSS.Style.ID> {
        let existingPropertiesByStyleID = propertiesByStyleID(in: sections)
        let incomingPropertiesByStyleID = propertiesByStyleID(in: incomingSections)
        let allStyleIDs = Set(existingPropertiesByStyleID.keys)
            .union(incomingPropertiesByStyleID.keys)
        return Set(allStyleIDs.filter { styleID in
            existingPropertiesByStyleID[styleID]?.map(\.name)
                != incomingPropertiesByStyleID[styleID]?.map(\.name)
        })
    }

    private func propertiesByStyleID(
        in sections: [CSSStyleSection]
    ) -> [CSS.Style.ID: [CSSStyleProperty]] {
        cssPropertiesByStyleID(in: sections)
    }

    private func hasEqualDeclarationContent(
        _ lhs: CSSStyleProperty,
        _ rhs: CSSStyleProperty
    ) -> Bool {
        lhs.name == rhs.name
            && lhs.value == rhs.value
            && lhs.priority == rhs.priority
            && lhs.text == rhs.text
            && lhs.parsedOk == rhs.parsedOk
            && lhs.status == rhs.status
            && lhs.implicit == rhs.implicit
            && lhs.range == rhs.range
            && lhs.isEditable == rhs.isEditable
            && lhs.isModifiedByInspector == rhs.isModifiedByInspector
    }

}
