import SwiftUI
import WebKit

public struct WIDOMView: View {
    @Environment(WIViewModel.self) private var model

    public init() {}
    
    public var body: some View {
        WIDOMViewRepresentable(bridge: model.webBridge)
            .ignoresSafeArea()
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
    }
}

@MainActor
struct WIDOMViewRepresentable {
    var bridge: WIBridge
}

#if os(macOS)
extension WIDOMViewRepresentable: NSViewRepresentable {
    typealias Coordinator = WIBridge

    func makeNSView(context: Context) -> WIWebView {
        bridge.inspectorModel.makeInspectorWebView()
    }

    func updateNSView(_ nsView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        bridge
    }
}
#else
extension WIDOMViewRepresentable: UIViewRepresentable {
    typealias Coordinator = WIBridge

    func makeUIView(context: Context) -> WIWebView {
        bridge.inspectorModel.makeInspectorWebView()
    }

    func updateUIView(_ uiView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        bridge
    }
}
#endif
