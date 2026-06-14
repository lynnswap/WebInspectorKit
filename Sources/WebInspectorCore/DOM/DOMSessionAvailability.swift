extension DOMSession {
    package var canReloadDocument: Bool {
        hasActiveCommandChannel && currentPageTargetID != nil
    }

    package var canBeginElementPicker: Bool {
        hasActiveCommandChannel && currentPageTargetID != nil
    }

    package var canSelectElement: Bool {
        hasActiveCommandChannel && currentPageRootNode != nil
    }

    package var canCopySelectedNodeText: Bool {
        hasActiveCommandChannel && selectedNodeID != nil
    }

    package var canDeleteSelectedNode: Bool {
        hasActiveCommandChannel && selectedNodeID != nil
    }

    private var hasActiveCommandChannel: Bool {
        _ = commandAvailabilityRevision
        return commandChannel?.acceptsActiveCommands == true
    }
}
