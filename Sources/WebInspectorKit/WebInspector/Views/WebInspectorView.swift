import SwiftUI
import WebKit
import Observation


// MARK: - Main View

public struct WebInspectorView: View {
    private let model: WIViewModel
    private let webView: WKWebView?
    private let tabs: [InspectorTab]

    public init(
        _ viewModel: WIViewModel,
        webView: WKWebView?,
        @InspectorTabsBuilder tabs: () -> [InspectorTab]
    ) {
        self.model = viewModel
        self.webView = webView
        self.tabs = tabs()
    }

    public init(
        _ viewModel: WIViewModel,
        webView: WKWebView?
    ) {
        self.init(viewModel, webView: webView) {
            InspectorTab.dom()
            InspectorTab.detail()
        }
    }

    public var body: some View {
        tabContent
            .onAppear {
                model.attach(webView: webView)
            }
            .onChange(of: webView) {
                model.attach(webView: webView)
            }
            .onDisappear {
                model.suspend()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.toggleSelectionMode()
                    } label: {
                        Image(systemName: model.isSelectingElement ? "viewfinder.circle.fill" : "viewfinder.circle")
                    }
                    .disabled(!model.hasPageWebView)
                }
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        if model.webBridge.isLoading {
                            ProgressView()
                        } else {
                            Label{
                                Text("reload")
                            }icon:{
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                    .disabled(model.webBridge.isLoading)
                    
                    Menu{
                        Button{
                            model.copySelection(.html)
                        }label:{
                            Text("HTML" as String)
                        }
                        Button{
                            model.copySelection(.selectorPath)
                        }label:{
                            Text("dom.detail.copy.selector_path")
                        }
                        Button{
                            model.copySelection(.xpath)
                        }label:{
                            Text("XPath" as String)
                        }
                    }label:{
                        Label{
                            Text("Copy")
                        }icon:{
                            Image(systemName:"document.on.document")
                        }
                    }
                    .disabled(model.webBridge.domSelection.nodeId == nil)
                    
                    Button(role:.destructive){
                        model.deleteSelectedNode()
                    }label:{
                        Label{
                            Text("inspector.delete_node")
                        }icon:{
                            Image(systemName:"trash")
                        }
                    }
                    .disabled(model.webBridge.domSelection.nodeId == nil)
                }
            }
            .environment(model)
    }

    @ViewBuilder
    private var tabContent: some View {
#if canImport(UIKit)
        WITabBarContainer(tabs: tabs)
            .ignoresSafeArea()
#else
        TabView {
            ForEach(tabs) { tab in
                tab.makeContent()
                    .tabItem {
                        Label {
                            Text(tab.title)
                        } icon: {
                            Image(systemName: tab.systemImage)
                        }
                    }
                    .tag(tab.id)
            }
        }
        .environment(model)
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
    @State private var inspectorModel = WIViewModel()
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if let model {
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
