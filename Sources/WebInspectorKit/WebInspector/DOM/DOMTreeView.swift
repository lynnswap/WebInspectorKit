import SwiftUI

extension WebInspector {
    public struct DOMTreeView: View {
        private let inspector: DOMInspector

        public init(inspector: DOMInspector) {
            self.inspector = inspector
        }

        public var body: some View {
            DOMTreeViewRepresentable(frontendStore: inspector.frontendStore)
                .ignoresSafeArea()
                .overlay {
                    if let errorMessage = inspector.errorMessage {
                        ContentUnavailableView {
                            Image(systemName: "exclamationmark.triangle")
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
}

@MainActor
private struct DOMTreeViewRepresentable {
    var frontendStore: DOMFrontendStore
}

#if os(macOS)
extension DOMTreeViewRepresentable: NSViewRepresentable {
    typealias Coordinator = DOMFrontendStore

    func makeNSView(context: Context) -> InspectorWebView {
        frontendStore.makeInspectorWebView()
    }

    func updateNSView(_ nsView: InspectorWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        frontendStore
    }
}
#else
extension DOMTreeViewRepresentable: UIViewRepresentable {
    typealias Coordinator = DOMFrontendStore

    func makeUIView(context: Context) -> InspectorWebView {
        frontendStore.makeInspectorWebView()
    }

    func updateUIView(_ uiView: InspectorWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        frontendStore
    }
}
#endif
