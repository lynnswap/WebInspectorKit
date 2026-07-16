#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorUINetwork

/// Owns controllers and models whose lifetime is bounded by one root
/// inspector presentation.
@MainActor
package final class PresentationContentStore {
    private let contentCache = WebInspectorTab.ContentCache()
    private let onElementPickerActivated: @MainActor () -> Void
    private var networkPanelModel: NetworkPanelModel?
    private var contextEpoch: Int?

    package init(
        onElementPickerActivated: @escaping @MainActor () -> Void = {}
    ) {
        self.onElementPickerActivated = onElementPickerActivated
    }

    isolated deinit {
        contentCache.removeAll()
    }

    package func viewController<Content: UIViewController>(
        for key: WebInspectorTab.ContentKey,
        contextEpoch: Int,
        make: () -> Content
    ) -> Content {
        prepare(for: contextEpoch)
        return contentCache.viewController(for: key, epoch: contextEpoch, make: make)
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

    package func pruneContent(retaining keys: Set<WebInspectorTab.ContentKey>) {
        contentCache.prune(retaining: keys)
    }

    package func clear() {
        clearResources()
        contextEpoch = nil
    }

    package func elementPickerDidActivate() {
        onElementPickerActivated()
    }

    private func clearResources() {
        networkPanelModel = nil
        contentCache.removeAll()
    }

    #if DEBUG
    package var contentCountForTesting: Int {
        contentCache.countForTesting
    }

    package var networkPanelModelForTesting: NetworkPanelModel? {
        networkPanelModel
    }
    #endif
}
#endif
