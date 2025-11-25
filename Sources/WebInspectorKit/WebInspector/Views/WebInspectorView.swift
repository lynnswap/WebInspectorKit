import SwiftUI
import WebKit
import Observation


// MARK: - Main View

public struct WebInspectorView: View {
    private var model: WIViewModel
    private var webView: WKWebView?

    public init(
        _ viewModel: WIViewModel,
        webView: WKWebView?
    ) {
        self.webView = webView
        self.model = viewModel
    }

    public var body: some View {
        tabContent
            .onAppear {
                model.handleAppear(webView: webView)
            }
            .onChange(of: webView) {
                model.handleAppear(webView: webView)
            }
            .onDisappear {
                model.handleDisappear()
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
                            model.copySelectionHTML()
                        }label:{
                            Text("HTML" as String)
                        }
                        Button{
                            model.copySelectionSelectorPath()
                        }label:{
                            Text("dom.detail.copy.selector_path")
                        }
                        Button{
                            model.copySelectionXPath()
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
    }

    @ViewBuilder
    private var tabContent: some View {
#if canImport(UIKit)
        WITabBarContainer(model: model)
            .ignoresSafeArea()
#else
        TabView {
            WIDOMView(model)
                .tabItem {
                    Label {
                        Text(InspectorTab.dom.title)
                    } icon: {
                        Image(systemName: InspectorTab.dom.systemImage)
                    }
                }
            WIDetailView(model)
                .tabItem {
                    Label {
                        Text(InspectorTab.detail.title)
                    } icon: {
                        Image(systemName: InspectorTab.detail.systemImage)
                    }
            }
        }
#endif
    }
}

// MARK: - Tab Metadata

enum InspectorTab: Int, CaseIterable {
    case dom
    case detail

    var title: LocalizedStringResource {
        switch self {
        case .dom:
            LocalizedStringResource("inspector.tab.dom", bundle: .module)
        case .detail:
            LocalizedStringResource("inspector.tab.detail", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .dom:
            "chevron.left.forwardslash.chevron.right"
        case .detail:
            "info.circle"
        }
    }

    var tag: Int { rawValue }
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
