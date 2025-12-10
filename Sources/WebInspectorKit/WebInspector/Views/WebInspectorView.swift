import SwiftUI
import WebKit
import Observation


// MARK: - Main View

public struct WebInspectorView: View {
    private let model: WebInspectorModel
    private let webView: WKWebView?
    private let tabs: [WITab]

    public init(
        _ viewModel: WebInspectorModel,
        webView: WKWebView?,
        @WITabBuilder tabs: () -> [WITab]
    ) {
        self.model = viewModel
        self.webView = webView
        self.tabs = tabs()
        if viewModel.selectedTab == nil {
            viewModel.selectedTab = self.tabs.first
        }
    }

    public init(
        _ viewModel: WebInspectorModel,
        webView: WKWebView?
    ) {
        self.init(viewModel, webView: webView) {
            WITab.dom()
            WITab.element()
            WITab.network()
        }
    }

    public var body: some View {
        tabContent
            .onAppear {
                if let webView {
                    model.attach(webView: webView)
                } else {
                    model.suspend()
                }
            }
            .onChange(of: webView) {
                if let webView {
                    model.attach(webView: webView)
                } else {
                    model.suspend()
                }
            }
            .onDisappear {
                model.suspend()
            }
    }

    @ViewBuilder
    private var tabContent: some View {
#if canImport(UIKit)
        WITabBarContainer(model: model, tabs: tabs)
            .ignoresSafeArea()
#elseif canImport(AppKit)
        WITabBarContainer(model: model, tabs: tabs)
#endif
    }
}

#if DEBUG
@MainActor
@Observable private final class WIPreviewModel {
    let webView: WKWebView
    
    init(url:URL) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.load(URLRequest(url: url))
    }
    
}
private struct WIPreviewHost: View {
    @State private var model :WIPreviewModel?
    @State private var isPresented:Bool = true
    @State private var inspectorModel = WebInspectorModel()
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if let model {
#if os(macOS)
            HSplitView{
                PreviewWebViewRepresentable(webView: model.webView)
                WebInspectorView(inspectorModel, webView: model.webView)
            }
#else
            PreviewWebViewRepresentable(webView: model.webView)
                .sheet(isPresented: $isPresented) {
                    NavigationStack {
                        WebInspectorView(inspectorModel, webView: model.webView)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button {
                                        isPresented = false
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                }
                            }
                            .background(backgroundColor.opacity(0.5))
                        
                    }
                    
                    .presentationBackgroundInteraction(.enabled)
                    .presentationDetents([.medium, .large])
                    .presentationContentInteraction(.scrolls)
                }
#endif
        }else{
            Color.clear
                .onAppear(){
                    self.model = WIPreviewModel(url:URL(string: "https://www.google.com")!)
                }
        }
    }
    private var backgroundColor:Color{
        if colorScheme == .dark{
            Color(red: 43/255, green: 43/255, blue: 43/255)
        }else{
            Color.white
        }
    }
}

#if os(macOS)
private struct PreviewWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct PreviewWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

#Preview("WebInspector Sheet") {
    WIPreviewHost()
#if os(macOS)
        .frame(width: 800, height: 600)
#endif
}
#endif
