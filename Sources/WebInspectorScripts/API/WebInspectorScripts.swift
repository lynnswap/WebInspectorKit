import Foundation

public enum WebInspectorScriptsError: LocalizedError, Sendable {
    case scriptUnavailable(name: String)

    public var errorDescription: String? {
        switch self {
        case let .scriptUnavailable(name):
            return "Script unavailable: \(name)"
        }
    }
}

public enum WebInspectorScripts {
    public static let domTreeViewResourceSubdirectory = "Resources/DOMTreeView"

    @MainActor private static var cachedDOMAgent: String?
    @MainActor private static var cachedNetworkAgent: String?
    @MainActor private static var cachedDOMTreeView: String?

    public static var resourceBundle: Bundle {
        Bundle.module
    }

    public static func resourceURL(
        named name: String,
        withExtension fileExtension: String,
        subdirectory: String? = nil
    ) -> URL? {
        if let subdirectory {
            return resourceBundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            )
        }
        return resourceBundle.url(forResource: name, withExtension: fileExtension)
    }

    @MainActor
    public static func domAgent() throws -> String {
        if let cachedDOMAgent {
            return cachedDOMAgent
        }
        guard let script = ScriptBundle.source(named: "dom-agent"), !script.isEmpty else {
            throw WebInspectorScriptsError.scriptUnavailable(name: "dom-agent")
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
            throw WebInspectorScriptsError.scriptUnavailable(name: "network-agent")
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
            throw WebInspectorScriptsError.scriptUnavailable(name: "dom-tree-view")
        }
        cachedDOMTreeView = script
        return script
    }
}
