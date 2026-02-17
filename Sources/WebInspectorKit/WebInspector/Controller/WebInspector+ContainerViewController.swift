import WebKit

#if canImport(UIKit)
import UIKit

extension WebInspector {
    @MainActor
    public final class ContainerViewController: UITabBarController, UITabBarControllerDelegate {
        public private(set) var inspectorController: Controller

        private weak var pageWebView: WKWebView?
        private var tabDescriptors: [TabDescriptor]

        public init(
            _ inspectorController: Controller,
            webView: WKWebView?,
            tabs: [TabDescriptor] = [.dom(), .element(), .network()]
        ) {
            self.inspectorController = inspectorController
            self.pageWebView = webView
            self.tabDescriptors = tabs
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        public func setPageWebView(_ webView: WKWebView?) {
            pageWebView = webView
            if isViewLoaded {
                inspectorController.connect(to: webView)
            }
        }

        public func setInspectorController(_ inspectorController: Controller) {
            guard self.inspectorController !== inspectorController else {
                return
            }
            let previousController = self.inspectorController
            previousController.onSelectedTabIDChange = nil
            previousController.disconnect()
            self.inspectorController = inspectorController
            bindSelectionCallback()
            if isViewLoaded {
                rebuildTabs()
                inspectorController.connect(to: pageWebView)
            }
        }

        public func setTabs(_ tabs: [TabDescriptor]) {
            tabDescriptors = tabs
            inspectorController.configureTabs(tabDescriptors)
            if isViewLoaded {
                rebuildTabs()
            }
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            delegate = self
            tabBar.scrollEdgeAppearance = tabBar.standardAppearance
            view.backgroundColor = .systemBackground

            bindSelectionCallback()
            rebuildTabs()
        }

        public override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            inspectorController.connect(to: pageWebView)
            syncNativeSelection(with: inspectorController.selectedTabID)
        }

        public override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if view.window == nil {
                inspectorController.suspend()
            }
        }

        private func rebuildTabs() {
            inspectorController.configureTabs(tabDescriptors)
            let context = TabContext(controller: inspectorController)
            var controllers: [UIViewController] = []
            controllers.reserveCapacity(tabDescriptors.count)

            for (index, descriptor) in tabDescriptors.enumerated() {
                let viewController = descriptor.makeViewController(context: context)
                viewController.tabBarItem = UITabBarItem(
                    title: descriptor.title,
                    image: UIImage(systemName: descriptor.systemImage),
                    tag: index
                )
                controllers.append(viewController)
            }

            setViewControllers(controllers, animated: false)
            syncNativeSelection(with: inspectorController.selectedTabID)
        }

        private func bindSelectionCallback() {
            inspectorController.onSelectedTabIDChange = { [weak self] tabID in
                guard let self else { return }
                self.syncNativeSelection(with: tabID)
            }
        }

        private func syncNativeSelection(with tabID: TabDescriptor.ID?) {
            guard tabDescriptors.isEmpty == false else {
                return
            }

            if let tabID,
               let index = tabDescriptors.firstIndex(where: { $0.id == tabID }) {
                if selectedIndex != index {
                    selectedIndex = index
                }
                return
            }

            let fallbackIndex = selectedIndex != NSNotFound ? selectedIndex : 0
            let resolvedIndex = tabDescriptors.indices.contains(fallbackIndex) ? fallbackIndex : 0
            if selectedIndex != resolvedIndex {
                selectedIndex = resolvedIndex
            }
            inspectorController.synchronizeSelectedTabFromNativeUI(tabDescriptors[resolvedIndex].id)
        }

        public func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            guard
                let index = viewControllers?.firstIndex(of: viewController),
                tabDescriptors.indices.contains(index)
            else {
                return
            }
            inspectorController.synchronizeSelectedTabFromNativeUI(tabDescriptors[index].id)
        }
    }
}

#elseif canImport(AppKit)
import AppKit

extension WebInspector {
    @MainActor
    public final class ContainerViewController: NSTabViewController {
        public private(set) var inspectorController: Controller

        private weak var pageWebView: WKWebView?
        private var tabDescriptors: [TabDescriptor]

        public init(
            _ inspectorController: Controller,
            webView: WKWebView?,
            tabs: [TabDescriptor] = [.dom(), .element(), .network()]
        ) {
            self.inspectorController = inspectorController
            self.pageWebView = webView
            self.tabDescriptors = tabs
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        public func setPageWebView(_ webView: WKWebView?) {
            pageWebView = webView
            if isViewLoaded {
                inspectorController.connect(to: webView)
            }
        }

        public func setInspectorController(_ inspectorController: Controller) {
            guard self.inspectorController !== inspectorController else {
                return
            }
            let previousController = self.inspectorController
            previousController.onSelectedTabIDChange = nil
            previousController.disconnect()
            self.inspectorController = inspectorController
            bindSelectionCallback()
            if isViewLoaded {
                rebuildTabs()
                inspectorController.connect(to: pageWebView)
            }
        }

        public func setTabs(_ tabs: [TabDescriptor]) {
            tabDescriptors = tabs
            inspectorController.configureTabs(tabDescriptors)
            if isViewLoaded {
                rebuildTabs()
            }
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            tabStyle = .segmentedControlOnTop

            bindSelectionCallback()
            rebuildTabs()
        }

        public override func viewWillAppear() {
            super.viewWillAppear()
            inspectorController.connect(to: pageWebView)
            syncNativeSelection(with: inspectorController.selectedTabID)
        }

        public override func viewDidDisappear() {
            super.viewDidDisappear()
            if view.window == nil {
                inspectorController.suspend()
            }
        }

        public override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            guard
                let identifier = tabViewItem?.identifier as? String
            else {
                return
            }
            inspectorController.synchronizeSelectedTabFromNativeUI(identifier)
        }

        private func rebuildTabs() {
            inspectorController.configureTabs(tabDescriptors)
            let context = TabContext(controller: inspectorController)
            tabViewItems = tabDescriptors.map { descriptor in
                let viewController = descriptor.makeViewController(context: context)
                let item = NSTabViewItem(viewController: viewController)
                item.identifier = descriptor.id
                item.label = descriptor.title
                item.image = NSImage(systemSymbolName: descriptor.systemImage, accessibilityDescription: descriptor.title)
                return item
            }
            syncNativeSelection(with: inspectorController.selectedTabID)
        }

        private func bindSelectionCallback() {
            inspectorController.onSelectedTabIDChange = { [weak self] tabID in
                guard let self else { return }
                self.syncNativeSelection(with: tabID)
            }
        }

        private func syncNativeSelection(with tabID: TabDescriptor.ID?) {
            guard tabDescriptors.isEmpty == false else {
                return
            }

            if let tabID,
               let index = tabDescriptors.firstIndex(where: { $0.id == tabID }) {
                if selectedTabViewItemIndex != index {
                    selectedTabViewItemIndex = index
                }
                return
            }

            let resolvedIndex = tabDescriptors.indices.contains(selectedTabViewItemIndex) ? selectedTabViewItemIndex : 0
            if selectedTabViewItemIndex != resolvedIndex {
                selectedTabViewItemIndex = resolvedIndex
            }
            inspectorController.synchronizeSelectedTabFromNativeUI(tabDescriptors[resolvedIndex].id)
        }
    }
}

#endif
