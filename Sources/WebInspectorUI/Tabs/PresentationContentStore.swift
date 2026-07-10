#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorUINetwork

/// Owns view controllers and models whose lifetime is bounded by one root
/// inspector presentation.
@MainActor
package final class PresentationContentStore {
    private let contentCache = WebInspectorTab.ContentCache()
    private var networkPanelModel: NetworkPanelModel?
    private var contextEpoch: Int?

    package init() {}

    isolated deinit {
        clearResources()
    }

    package func viewController<Content: UIViewController>(
        for key: WebInspectorTab.ContentKey,
        contextEpoch: Int,
        make: () -> Content
    ) -> Content {
        prepare(for: contextEpoch)
        return contentCache.viewController(for: key, make: make)
    }

    package func networkPanelModel(
        for context: WebInspectorContext,
        contextEpoch: Int
    ) -> NetworkPanelModel {
        prepare(for: contextEpoch)
        if let networkPanelModel {
            precondition(
                networkPanelModel.context === context,
                "A presentation context must change together with its context epoch."
            )
            return networkPanelModel
        }

        let model = NetworkPanelModel(context: context)
        networkPanelModel = model
        return model
    }

    package func prepare(for contextEpoch: Int) {
        guard self.contextEpoch != contextEpoch else {
            return
        }
        clearResources()
        self.contextEpoch = contextEpoch
    }

    package func clear() {
        clearResources()
        contextEpoch = nil
    }

    private func clearResources() {
        networkPanelModel = nil
        contentCache.removeAll()
    }

    #if DEBUG
    package var contentCountForTesting: Int {
        contentCache.countForTesting
    }

    package var contentCacheForTesting: WebInspectorTab.ContentCache {
        contentCache
    }
    #endif
}
#endif
