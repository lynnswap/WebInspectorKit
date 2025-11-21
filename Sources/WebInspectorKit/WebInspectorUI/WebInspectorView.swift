import SwiftUI
import WebKit
import Observation

struct WebInspectorSnapshotPackage {
    let rawJSON: String
}

struct WebInspectorSubtreePayload: Equatable {
    let rawJSON: String
}

struct WebInspectorDOMUpdatePayload: Equatable {
    let rawJSON: String
}

struct WebInspectorSelectionResult: Decodable {
    let cancelled: Bool
    let requiredDepth: Int
}


// MARK: - Main View

public struct WebInspectorView: View {
    var webView: WKWebView?
    @Environment(\.dismiss) private var dismiss

    @State private var model = WebInspectorViewModel()

    public init(webView: WKWebView?) {
        self.webView = webView
    }

    public var body: some View {

        NavigationStack {
            ZStack {
                WebInspectorWebContainer(bridge: model.webBridge)

                if let errorMessage = model.webBridge.errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .font(.callout)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: 320)
                    .transition(.opacity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.toggleSelectionMode()
                    } label: {
                        Image(systemName: model.isSelectingElement ? "viewfinder.circle.fill" : "viewfinder.circle")
                    }
                    .disabled(!model.hasPageWebView)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        if model.webBridge.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(model.webBridge.isLoading)
                }
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
    }
}

// MARK: - WebContainer Representable

private struct WebInspectorWebContainer: View {
    var bridge: WebInspectorBridge
    @State private var searchText = ""
    @State private var lastSubmittedSearchTerm: String?

    var body: some View {
        WebInspectorWebViewContainerRepresentable(bridge: bridge)
            .ignoresSafeArea()
            .searchable(text: $searchText)
            .onAppear {
                submitSearchTerm(searchText, force: true)
            }
            .onChange(of: searchText) {
                submitSearchTerm(searchText)
            }
    }

    private func submitSearchTerm(_ term: String, force: Bool = false) {
        guard force || lastSubmittedSearchTerm != term else { return }
        lastSubmittedSearchTerm = term
        bridge.updateSearchTerm(term)
    }
}

@MainActor
struct WebInspectorWebViewContainerRepresentable {
    var bridge: WebInspectorBridge
}

#if os(macOS)
extension WebInspectorWebViewContainerRepresentable: NSViewRepresentable {
    typealias Coordinator = WebInspectorBridge

    func makeNSView(context: Context) -> WKWebView {
        bridge.makeInspectorWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        bridge
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: WebInspectorCoordinator.handlerName)
        coordinator.teardownInspectorWebView(nsView)
    }
}
#else
extension WebInspectorWebViewContainerRepresentable: UIViewRepresentable {
    typealias Coordinator = WebInspectorBridge

    func makeUIView(context: Context) -> WKWebView {
        bridge.makeInspectorWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        bridge
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: WebInspectorCoordinator.handlerName)
        coordinator.teardownInspectorWebView(uiView)
    }
}
#endif

// MARK: - Asset helpers

enum WebInspectorAssets {
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

enum WebInspectorError: LocalizedError {
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
@Observable private final class WebInspectorPreviewModel {
    let webView: WKWebView
    
    init(url:URL) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.load(URLRequest(url: url))
    }
    
}
private struct WebInspectorPreviewHost: View {
    @State private var model :WebInspectorPreviewModel?
    @State private var isPresented:Bool = true
    var body: some View {
        if let model {
            PreviewWebViewRepresentable(webView: model.webView)
                .sheet(isPresented: $isPresented) {
                    WebInspectorView(webView: model.webView)
                        .presentationBackgroundInteraction(.enabled)
                        .presentationDetents([.medium, .large])
                        .presentationContentInteraction(.scrolls)
                }
        }else{
            Color.clear
                .onAppear(){
                    self.model = WebInspectorPreviewModel(url:URL(string: "https://www.google.com")!)
                }
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
    WebInspectorPreviewHost()
#if os(macOS)
        .frame(width: 800, height: 600)
#endif
}
#endif
