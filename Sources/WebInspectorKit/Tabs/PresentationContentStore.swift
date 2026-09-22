#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorUINetwork

/// Owns controllers and models whose lifetime is bounded by one root
/// inspector presentation.
@MainActor
final class PresentationContentStore {
    private let contentCache = WebInspectorTab.ContentCache()
    private var networkPanelModel: NetworkPanelModel?
    private var contextEpoch: Int?

    init() {}

    isolated deinit {
        contentCache.removeAll()
    }

    func viewController<Content: UIViewController>(
        for key: WebInspectorTab.ContentKey,
        contextEpoch: Int,
        make: () -> Content
    ) -> Content {
        prepare(for: contextEpoch)
        return contentCache.viewController(for: key, epoch: contextEpoch, make: make)
    }

    func networkPanelModel(
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

    func prepare(for contextEpoch: Int) {
        guard self.contextEpoch != contextEpoch else {
            return
        }
        clearResources()
        self.contextEpoch = contextEpoch
    }

    func pruneContent(retaining keys: Set<WebInspectorTab.ContentKey>) {
        contentCache.prune(retaining: keys)
    }

    func clear() {
        clearResources()
        contextEpoch = nil
    }

    private func clearResources() {
        networkPanelModel = nil
        contentCache.removeAll()
    }

    #if DEBUG
    var contentCountForTesting: Int {
        contentCache.countForTesting
    }

    var networkPanelModelForTesting: NetworkPanelModel? {
        networkPanelModel
    }
    #endif
}
#endif
