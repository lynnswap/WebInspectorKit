import SwiftUI
import WebKit

public struct WIDOMView: View {
    private var viewModel: WIDOMViewModel

    public init(viewModel: WIDOMViewModel ) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        WIDOMViewRepresentable(inspectorModel: viewModel.inspectorModel)
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
    var inspectorModel: WIInspectorModel
}

#if os(macOS)
extension WIDOMViewRepresentable: NSViewRepresentable {
    typealias Coordinator = WIInspectorModel

    func makeNSView(context: Context) -> WIWebView {
        inspectorModel.makeInspectorWebView()
    }

    func updateNSView(_ nsView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        inspectorModel
    }
}
#else
extension WIDOMViewRepresentable: UIViewRepresentable {
    typealias Coordinator = WIInspectorModel

    func makeUIView(context: Context) -> WIWebView {
        inspectorModel.makeInspectorWebView()
    }

    func updateUIView(_ uiView: WIWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        inspectorModel
    }
}
#endif
