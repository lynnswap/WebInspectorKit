import SwiftUI
import WebInspectorKit

struct ContentView: View {
    @Environment(\.windowScene) private var windowScene
    @State private var model: BrowserViewModel?
    @State private var inspectorController: WISessionController?
    
    var body: some View {
        if let model, let inspectorController {
            NavigationStack {
                ContentWebView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
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
                        }
                    }
            }
        } else {
            Color.clear
                .onAppear {
                    model = BrowserViewModel(url: URL(string: "https://www.google.com")!)
                    inspectorController = WISessionController()
                }
        }
    }
}

#Preview {
    ContentView()
}
