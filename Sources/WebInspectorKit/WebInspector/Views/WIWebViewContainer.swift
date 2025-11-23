import SwiftUI
import WebKit

@MainActor
struct WIWebViewContainerRepresentable {
    var bridge: WIBridge
}

#if os(macOS)
extension WIWebViewContainerRepresentable: NSViewRepresentable {
    typealias Coordinator = WIBridge

    func makeNSView(context: Context) -> WIWebView {
        bridge.makeInspectorWebView()
    }

    func updateNSView(_ nsView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        bridge
    }

    static func dismantleNSView(_ nsView: WIWebView, coordinator: Coordinator) {
        coordinator.teardownInspectorWebView(nsView)
    }
}
#else
extension WIWebViewContainerRepresentable: UIViewRepresentable {
    typealias Coordinator = WIBridge

    func makeUIView(context: Context) -> WIWebView {
        bridge.makeInspectorWebView()
    }

    func updateUIView(_ uiView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        bridge
    }

    static func dismantleUIView(_ uiView: WIWebView, coordinator: Coordinator) {
        coordinator.teardownInspectorWebView(uiView)
    }
}
#endif
