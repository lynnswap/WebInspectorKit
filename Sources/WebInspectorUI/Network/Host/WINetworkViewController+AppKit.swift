import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
public final class WINetworkViewController: NSSplitViewController {
    private static let splitViewAutosaveName = NSSplitView.AutosaveName("WebInspectorKit.NetworkSplitView")

    private let inspector: WINetworkModel
    private let queryModel: WINetworkQueryModel
    private let listViewController: WINetworkListViewController
    private let detailViewController: WINetworkDetailViewController
    private var observationHandles: Set<ObservationHandle> = []

    public convenience init(inspector: WINetworkModel) {
        self.init(
            inspector: inspector,
            queryModel: WINetworkQueryModel(inspector: inspector)
        )
    }

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        self.queryModel = queryModel
        self.listViewController = WINetworkListViewController(inspector: inspector, queryModel: queryModel)
        self.detailViewController = WINetworkDetailViewController(inspector: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    var listViewControllerForTesting: WINetworkListViewController {
        listViewController
    }

    var detailViewControllerForTesting: WINetworkDetailViewController {
        detailViewController
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = Self.splitViewAutosaveName
        inspector.selectEntry(nil)
        listViewController.loadViewIfNeeded()
        detailViewController.loadViewIfNeeded()
        startObservingInspector()

        let listItem = NSSplitViewItem(contentListWithViewController: listViewController)
        listItem.minimumThickness = 280
        listItem.canCollapse = false

        let detailItem = NSSplitViewItem(viewController: detailViewController)
        detailItem.minimumThickness = 320

        splitViewItems = [listItem, detailItem]
    }

    private func startObservingInspector() {
        inspector.observeTask(
            \.displayEntriesGeneration,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.listViewController.reloadDataFromInspector()
            self.detailViewController.display(self.inspector.selectedEntry)
        }
        .store(in: &observationHandles)

        inspector.observeTask(
            [\.selectedEntry]
        ) { [weak self] in
            guard let self else {
                return
            }
            self.listViewController.syncSelectionFromModel()
            self.detailViewController.display(self.inspector.selectedEntry)
        }
        .store(in: &observationHandles)
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Root (AppKit)") {
    WIAppKitPreviewContainer {
        WINetworkViewController(inspector: WINetworkPreviewFixtures.makeInspector(mode: .root))
    }
}

#Preview("Network Root Long Title (AppKit)") {
    WIAppKitPreviewContainer {
        WINetworkViewController(inspector: WINetworkPreviewFixtures.makeInspector(mode: .rootLongTitle))
    }
}
#endif

#endif
