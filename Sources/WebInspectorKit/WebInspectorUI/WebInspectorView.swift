import SwiftUI
import WebKit
import Observation

struct WISnapshotPackage {
    let rawJSON: String
}

struct WISubtreePayload: Equatable {
    let rawJSON: String
}

struct WIDOMUpdatePayload: Equatable {
    let rawJSON: String
}

public struct WIDOMAttribute: Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct WIDOMSelection: Equatable {
    public let nodeId: Int?
    public let preview: String
    public let description: String
    public let attributes: [WIDOMAttribute]
    public let path: [String]

    public init(
        nodeId: Int?,
        preview: String,
        description: String,
        attributes: [WIDOMAttribute],
        path: [String]
    ) {
        self.nodeId = nodeId
        self.preview = preview
        self.description = description
        self.attributes = attributes
        self.path = path
    }
}

struct WISelectionResult: Decodable {
    let cancelled: Bool
    let requiredDepth: Int
}


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
            .overlay{
                if let errorMessage = model.webBridge.errorMessage {
                    ContentUnavailableView {
                        Image(systemName:"exclamationmark.triangle")
                            .foregroundStyle(.yellow)
                    } description: {
                        Text(errorMessage)
                    }
                    .padding()
                    .frame(maxWidth: 320)
                    .transition(.opacity)
                }
            }
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
                    .disabled(model.webBridge.domSelection?.nodeId == nil)
                    
                    Button(role:.destructive){
                        model.deleteSelectedNode()
                    }label:{
                        Label{
                            Text("inspector.delete_node")
                        }icon:{
                            Image(systemName:"trash")
                        }
                    }
                    .disabled(model.webBridge.domSelection?.nodeId == nil)
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
            WIWebContainer(bridge: model.webBridge)
                .tabItem {
                    Label {
                        Text(InspectorTab.tree.title)
                    } icon: {
                        Image(systemName: InspectorTab.tree.systemImage)
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
    case tree
    case detail

    var title: LocalizedStringResource {
        switch self {
        case .tree:
            LocalizedStringResource("inspector.tab.tree", bundle: .module)
        case .detail:
            LocalizedStringResource("inspector.tab.detail", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .tree:
            "chevron.left.forwardslash.chevron.right"
        case .detail:
            "info.circle"
        }
    }

    var tag: Int { rawValue }
}


// MARK: - WebContainer Representable

private struct WIWebContainer: View {
    var bridge: WIBridge

    var body: some View {
        WIWebViewContainerRepresentable(bridge: bridge)
            .ignoresSafeArea()
    }
}

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

// MARK: - Asset helpers

enum WIAssets {
    private static let searchBundles = [Bundle.module, .main]

    static var mainFileURL: URL? {
        locateResource(named: "InspectorUI", withExtension: "html")
    }

    static var resourcesDirectory: URL? {
        mainFileURL?.deletingLastPathComponent()
    }

    static func locateResource(named name: String, withExtension fileExtension: String) -> URL? {
        for bundle in searchBundles {
            if let url = bundle.url(forResource: name, withExtension: fileExtension) {
                return url
            }
        }
        return nil
    }
}

// MARK: - PDWebView helpers

enum WIError: LocalizedError {
    case serializationFailed
    case subtreeUnavailable
    case scriptUnavailable
    
    var errorDescription: String? {
        switch self {
        case .serializationFailed:
            return "Failed to serialize DOM tree."
        case .subtreeUnavailable:
            return "Failed to load child nodes."
        case .scriptUnavailable:
            return "Failed to load web inspector script."
        }
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
