import Foundation

public enum WebInspectorScripts {
    @MainActor private static var cachedDOMAgent: String?
    @MainActor private static var cachedNetworkAgent: String?
    @MainActor private static var cachedDOMTreeView: String?

    @MainActor
    public static func domAgent() throws -> String {
        if let cachedDOMAgent {
            return cachedDOMAgent
        }
        guard let script = ScriptBundle.source(named: "dom-agent"), !script.isEmpty else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        cachedDOMAgent = script
        return script
    }

    @MainActor
    public static func networkAgent() throws -> String {
        if let cachedNetworkAgent {
            return cachedNetworkAgent
        }
        guard let script = ScriptBundle.source(named: "network-agent"), !script.isEmpty else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        cachedNetworkAgent = script
        return script
    }

    @MainActor
    public static func domTreeView() throws -> String {
        if let cachedDOMTreeView {
            return cachedDOMTreeView
        }
        guard let script = ScriptBundle.source(named: "dom-tree-view"), !script.isEmpty else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        cachedDOMTreeView = script
        return script
    }
}

