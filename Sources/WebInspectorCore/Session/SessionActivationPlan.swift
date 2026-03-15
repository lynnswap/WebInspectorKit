import Foundation

@MainActor
package struct SessionActivationPlan {
    package struct RuntimeAttachmentState: Sendable {
        package let domEnabled: Bool
        package let networkEnabled: Bool
        package let domAutoSnapshotEnabled: Bool
        package let networkMode: NetworkLoggingMode
    }

    package let selectedPanelConfiguration: WIPanelConfiguration?
    package let runtimeState: RuntimeAttachmentState

    package init(
        panelConfigurations: [WIPanelConfiguration],
        currentSelection: WIPanelConfiguration?,
        preferredSelection: WIPanelConfiguration?,
        hasConfiguredPanelsFromUI: Bool
    ) {
        selectedPanelConfiguration = Self.normalizedSelection(
            in: panelConfigurations,
            currentSelection: currentSelection,
            preferredSelection: preferredSelection
        )
        runtimeState = Self.runtimeState(
            for: panelConfigurations,
            selectedPanelConfiguration: selectedPanelConfiguration,
            hasConfiguredPanelsFromUI: hasConfiguredPanelsFromUI
        )
    }

    package static func resolveSelectionCandidate(
        _ requestedPanelConfiguration: WIPanelConfiguration?,
        in panelConfigurations: [WIPanelConfiguration]
    ) -> WIPanelConfiguration? {
        guard let requestedPanelConfiguration else {
            return nil
        }
        if let exactMatch = panelConfigurations.first(where: { $0 == requestedPanelConfiguration }) {
            return exactMatch
        }

        let identifierMatches = panelConfigurations.filter {
            $0.identifier == requestedPanelConfiguration.identifier
        }
        if identifierMatches.count == 1, let identifierMatch = identifierMatches.first {
            return identifierMatch
        }

        if requestedPanelConfiguration.kind == .domDetail {
            let hasDOMTreePanel = panelConfigurations.contains { $0.kind == .domTree }
            let hasDOMDetailPanel = panelConfigurations.contains { $0.kind == .domDetail }
            if hasDOMTreePanel, hasDOMDetailPanel == false {
                return requestedPanelConfiguration
            }
        }

        return nil
    }
}

private extension SessionActivationPlan {
    static func normalizedSelection(
        in panelConfigurations: [WIPanelConfiguration],
        currentSelection: WIPanelConfiguration?,
        preferredSelection: WIPanelConfiguration?
    ) -> WIPanelConfiguration? {
        if panelConfigurations.isEmpty {
            return nil
        }
        if let preferredSelection,
           let resolvedPreferred = resolveSelectionCandidate(preferredSelection, in: panelConfigurations) {
            return resolvedPreferred
        }
        if let currentSelection,
           let resolvedCurrent = resolveSelectionCandidate(currentSelection, in: panelConfigurations) {
            return resolvedCurrent
        }
        return panelConfigurations.first
    }

    static func runtimeState(
        for panelConfigurations: [WIPanelConfiguration],
        selectedPanelConfiguration: WIPanelConfiguration?,
        hasConfiguredPanelsFromUI: Bool
    ) -> RuntimeAttachmentState {
        guard hasConfiguredPanelsFromUI else {
            return RuntimeAttachmentState(
                domEnabled: true,
                networkEnabled: true,
                domAutoSnapshotEnabled: true,
                networkMode: .active
            )
        }

        let hasDOMTreePanel = panelConfigurations.contains { $0.kind == .domTree }
        return RuntimeAttachmentState(
            domEnabled: panelConfigurations.contains {
                $0.kind == .domTree || $0.kind == .domDetail
            },
            networkEnabled: panelConfigurations.contains { $0.kind == .network },
            domAutoSnapshotEnabled: selectedPanelConfiguration?.kind == .domTree
                || (selectedPanelConfiguration?.kind == .domDetail && hasDOMTreePanel == false),
            networkMode: selectedPanelConfiguration?.kind == .network ? .active : .buffering
        )
    }
}
