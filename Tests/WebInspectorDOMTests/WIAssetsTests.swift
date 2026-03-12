import Foundation
import Testing
@testable import WebInspectorResources

struct WIAssetsTests {
    @Test
    func domTreeViewResourcesResolveFromBundle() throws {
        let mainFileURL = try #require(WIAssets.mainFileURL)
        let resourcesDirectory = try #require(WIAssets.resourcesDirectory)
        let readAccessURL = try #require(WIAssets.resourcesReadAccessURL)
        let stylesheetURL = try #require(WIAssets.stylesheetURL)
        let htmlSource = try String(contentsOf: mainFileURL, encoding: .utf8)
        let stylesheetSource = try WIAssets.stylesheetSource()

        #expect(FileManager.default.fileExists(atPath: mainFileURL.path))
        #expect(FileManager.default.fileExists(atPath: stylesheetURL.path))
        #expect(mainFileURL.deletingLastPathComponent() == resourcesDirectory)
        #expect(mainFileURL.path.hasSuffix("dom-tree-view.html"))
        #expect(stylesheetURL.path.hasSuffix("dom-tree-view.css"))
        #expect(readAccessURL.path.isEmpty == false)
        #expect(stylesheetSource.contains(".dom-tree"))
        #expect(stylesheetSource.contains("--background"))
        #expect(stylesheetSource.contains(".tree-node--document-root > .tree-node__row"))
        #expect(
            stylesheetSource.range(
                of: #"\.dom-tree-panel\s*\{[^}]*background:\s*var\(--inspector-panel-alt\)"#,
                options: .regularExpression
            ) == nil
        )
        #expect(
            stylesheetSource.range(
                of: #"\.dom-tree-panel\s*\{[^}]*border:\s*1px solid var\(--inspector-border\)"#,
                options: .regularExpression
            ) == nil
        )
        #expect(htmlSource.contains("deemphasize-unrendered"))
    }
}
