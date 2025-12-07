import SwiftUI
import WebKit

public struct WIDOMView: View {
    private var viewModel: WIDOMViewModel

    public init(viewModel: WIDOMViewModel ) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        WIDOMViewRepresentable(domStore: viewModel.domStore)
            .ignoresSafeArea()
            .overlay{
                if let errorMessage = viewModel.errorMessage {
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
    var domStore: WIDOMStore
}

#if os(macOS)
extension WIDOMViewRepresentable: NSViewRepresentable {
    typealias Coordinator = WIDOMStore

    func makeNSView(context: Context) -> WIWebView {
        domStore.makeInspectorWebView()
    }

    func updateNSView(_ nsView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        domStore
    }
}
#else
extension WIDOMViewRepresentable: UIViewRepresentable {
    typealias Coordinator = WIDOMStore

    func makeUIView(context: Context) -> WIWebView {
        domStore.makeInspectorWebView()
    }

    func updateUIView(_ uiView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        domStore
    }
}
#endif
