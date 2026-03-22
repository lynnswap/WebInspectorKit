import Observation

@MainActor
@Observable
public final class WIModel {
    public private(set) var lastRecoverableError: String?
    public private(set) var tabs: [WITab] = []
    public private(set) var selectedTab: WITab?
    package private(set) var preferredCompactSelectedTabIdentifier: String?
    package private(set) var hasExplicitTabsConfiguration = false

    public init() {}

    public func setTabs(_ tabs: [WITab]) {
        setTabsFromUI(tabs, marksExplicitConfiguration: true)
    }

    public func setSelectedTab(_ tab: WITab?) {
        _ = projectSelectedTabFromUI(tab)
    }

    public func setPreferredCompactSelectedTabIdentifier(_ identifier: String?) {
        setPreferredCompactSelectedTabIdentifierFromUI(identifier)
    }
}

extension WIModel {
    package func setRecoverableError(_ message: String?) {
        lastRecoverableError = message
    }

    package func setSelectedTabFromUI(_ tab: WITab?) {
        _ = projectSelectedTabFromUI(tab)
    }

    package func setTabsFromUI(
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
    package func projectSelectedTabFromUI(_ tab: WITab?) -> Bool {
        let resolvedTab = resolveSelectionCandidate(tab)
        if tab != nil, resolvedTab == nil {
            return false
        }
        applyNormalizedSelection(preferredTab: resolvedTab)
        return true
    }

    package func setPreferredCompactSelectedTabIdentifierFromUI(_ identifier: String?) {
        preferredCompactSelectedTabIdentifier = identifier
        syncPreferredCompactSelectionAfterNormalization(selectedTab)
    }
}

private extension WIModel {
    func applyNormalizedSelection(preferredTab: WITab?) {
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

        if normalizedTab !== selectedTab {
            selectedTab = normalizedTab
        }
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

    func syncPreferredCompactSelectionAfterNormalization(_ normalizedTab: WITab?) {
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
