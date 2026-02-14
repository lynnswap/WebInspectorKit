import SwiftUI
import WebKit

extension WebInspector {
    public struct Panel: View {
        private let controller: Controller
        private let webView: WKWebView?
        private let tabs: [Tab]

        @MainActor
        public init(
            _ controller: Controller,
            webView: WKWebView?,
            @TabBuilder tabs: () -> [Tab] = {
                [
                    .dom(),
                    .element(),
                    .network()
                ]
            }
        ) {
            self.controller = controller
            self.webView = webView
            let resolvedTabs = tabs()
            self.tabs = resolvedTabs
            controller.configureTabs(resolvedTabs)
        }

        public var body: some View {
            WebInspectorTabContainer(controller: controller, tabs: tabs)
                .ignoresSafeArea()
                .onAppear {
                    controller.connect(to: webView)
                }
                .onChange(of: webView) {
                    controller.connect(to: webView)
                }
                .onDisappear {
                    controller.suspend()
                }
        }
    }
}

