import Foundation
import SwiftUI

enum WIAssets {
    private static let searchBundles = [Bundle.module, .main]
    private static let inspectorSubdirectory = "WebInspector/Views/DOMTreeView"

    static var mainFileURL: URL? {
        locateResource(named: "DOMTreeView", withExtension: "html")
    }

    static var resourcesDirectory: URL? {
        mainFileURL?.deletingLastPathComponent()
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
