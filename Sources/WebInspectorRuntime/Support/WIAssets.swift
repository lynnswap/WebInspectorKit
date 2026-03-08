import Foundation
import WebInspectorScripts

enum WIAssets {
    private static let searchBundles = [WebInspectorScripts.resourceBundle, .main]
    private static let inspectorSubdirectory = WebInspectorScripts.domTreeViewResourceSubdirectory

    static var mainFileURL: URL? {
        locateResource(named: "dom-tree-view", withExtension: "html")
    }

    static var resourcesDirectory: URL? {
        mainFileURL?.deletingLastPathComponent()
    }

    static var resourcesReadAccessURL: URL? {
        resourcesDirectory
    }

    static var stylesheetURL: URL? {
        locateResource(named: "dom-tree-view", withExtension: "css")
    }

    static func stylesheetSource() throws -> String {
        guard let stylesheetURL else {
            throw WebInspectorScriptsError.scriptUnavailable(name: "dom-tree-view.css")
        }
        return try String(contentsOf: stylesheetURL, encoding: .utf8)
    }

    static func locateResource(
        named name: String,
        withExtension fileExtension: String,
        subdirectory: String? = inspectorSubdirectory
    ) -> URL? {
        for bundle in searchBundles {
            if let subdirectory,
               let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
               ) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: fileExtension) {
                return url
            }
        }
        return nil
    }
}
