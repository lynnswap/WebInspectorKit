import SwiftUI
import WebInspectorKit

struct ContentView: View {
    @State private var model: BrowserViewModel?
    @State private var inspectorController: WebInspector.Controller?
    @State private var isShowingInspector = false
   
    
    var body: some View {
        if let model, let inspectorController {
#if os(macOS)
            HSplitView {
                NavigationStack {
                    ContentWebView(model: model)
                }
                WebInspector.Panel(inspectorController, webView: model.webView)
            }
#else
            NavigationStack {
                ContentWebView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                isShowingInspector.toggle()
                            } label: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                            }
                        }
                    }
                    .sheet(isPresented: $isShowingInspector) {
                        InspectorSheetView(
                            model:model,
                            inspectorController: inspectorController
                        )
                        .presentationBackgroundInteraction(.enabled)
                        .presentationDetents([.medium, .large])
                        .presentationContentInteraction(.scrolls)
                    }
            }
#endif
        } else {
            Color.clear
                .onAppear {
                    model = BrowserViewModel(url: URL(string: "https://www.google.com")!)
                    inspectorController = WebInspector.Controller()
                }
        }
    }
}

#Preview {
    ContentView()
}
