import Foundation

@MainActor
package struct WIInspectorState {
    package var lastRecoverableError: String?
    package var tabs: [WITab] = []
    package var selectedTab: WITab?
    package var preferredCompactSelectedTabIdentifier: String?
    package var hasExplicitTabsConfiguration = false

    package init() {}

    package mutating func setRecoverableError(_ message: String?) {
        lastRecoverableError = message
    }

    package mutating func setTabs(
        _ tabs: [WITab],
        marksExplicitConfiguration: Bool = true
    ) {
        if marksExplicitConfiguration {
            hasExplicitTabsConfiguration = true
        }
        self.tabs = tabs
        applyNormalizedSelection(preferredTab: selectedTab)
    }

    @discardableResult
    package mutating func projectSelectedTab(_ tab: WITab?) -> Bool {
        let resolvedTab = resolveSelectionCandidate(tab)
        if tab != nil, resolvedTab == nil {
            return false
        }
        applyNormalizedSelection(preferredTab: resolvedTab)
        return true
    }

    package mutating func setPreferredCompactSelectedTabIdentifier(_ identifier: String?) {
        preferredCompactSelectedTabIdentifier = identifier
        syncPreferredCompactSelectionAfterNormalization(selectedTab)
    }
}

private extension WIInspectorState {
    mutating func applyNormalizedSelection(preferredTab: WITab?) {
        let normalizedTab: WITab?
        if tabs.isEmpty {
            normalizedTab = nil
        } else if let preferredTab,
                  let resolvedTab = resolveSelectionCandidate(preferredTab) {
            normalizedTab = resolvedTab
        } else if let currentSelection = selectedTab,
                  let resolvedCurrent = resolveSelectionCandidate(currentSelection) {
            normalizedTab = resolvedCurrent
        } else {
            normalizedTab = tabs.first
        }

        selectedTab = normalizedTab
        syncPreferredCompactSelectionAfterNormalization(normalizedTab)
    }

    func resolveSelectionCandidate(_ requestedTab: WITab?) -> WITab? {
        guard let requestedTab else {
            return nil
        }
        if let exactMatch = tabs.first(where: { $0 === requestedTab }) {
            return exactMatch
        }
        if let identifierMatch = tabs.first(where: { $0.identifier == requestedTab.identifier }) {
            return identifierMatch
        }
        if requestedTab.identifier == WITab.elementTabID,
           tabs.contains(where: { $0.identifier == WITab.domTabID }) {
            return requestedTab
        }
        return nil
    }

    mutating func syncPreferredCompactSelectionAfterNormalization(_ normalizedTab: WITab?) {
        guard let normalizedTab else {
            preferredCompactSelectedTabIdentifier = nil
            return
        }

        guard isValidCompactPreferredSelection(identifier: preferredCompactSelectedTabIdentifier) else {
            preferredCompactSelectedTabIdentifier = normalizedTab.identifier
            return
        }

        let hasDOMTab = tabs.contains { $0.identifier == WITab.domTabID }
        if normalizedTab.identifier == WITab.domTabID,
           hasDOMTab,
           preferredCompactSelectedTabIdentifier == WITab.elementTabID {
            return
        }

        preferredCompactSelectedTabIdentifier = normalizedTab.identifier
    }

    func isValidCompactPreferredSelection(identifier: String?) -> Bool {
        guard let identifier else {
            return false
        }
        if tabs.contains(where: { $0.identifier == identifier }) {
            return true
        }
        return identifier == WITab.elementTabID
            && tabs.contains(where: { $0.identifier == WITab.domTabID })
    }
}
