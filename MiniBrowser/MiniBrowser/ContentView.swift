import SwiftUI
import WebInspectorKit

struct ContentView: View {
    @Environment(\.windowScene) private var windowScene
    @State private var model: BrowserViewModel?
    @State private var inspectorController: WIModel?
    
    var body: some View {
        if let model, let inspectorController {
            NavigationStack {
                inspectorContent(model: model, inspectorController: inspectorController)
            }
        } else {
            Color.clear
                .onAppear {
                    model = BrowserViewModel(url: URL(string: "https://www.google.com")!)
                    inspectorController = WIModel()
                }
        }
    }

    @ViewBuilder
    private func inspectorContent(model: BrowserViewModel, inspectorController: WIModel) -> some View {
        ContentWebView(model: model)
#if os(iOS) && DEBUG
            .sheet(
                isPresented: Binding(
                    get: { model.isNativeInspectorProbeSheetPresented },
                    set: { model.isNativeInspectorProbeSheetPresented = $0 }
                )
            ) {
                NativeInspectorProbeResultSheet(
                    result: model.nativeInspectorProbeResult,
                    isRunning: model.isNativeInspectorProbeRunning
                )
            }
            .task {
                model.maybeAutoStartNativeInspectorProbe()
            }
#endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        presentWebInspector(
                            windowScene: windowScene,
                            model: model,
                            inspectorController: inspectorController
                        )
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("MiniBrowser.openInspectorButton")

#if os(iOS) && DEBUG
                    Button {
                        model.startNativeInspectorProbe()
                    } label: {
                        Image(systemName: "scope")
                    }
                    .disabled(model.isNativeInspectorProbeRunning)
                    .accessibilityIdentifier("MiniBrowser.nativeInspectorProbeButton")
#endif
                }
            }
    }
}

#Preview {
    ContentView()
}
