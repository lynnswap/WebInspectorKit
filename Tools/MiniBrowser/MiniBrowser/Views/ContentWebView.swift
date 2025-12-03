import SwiftUI
import Observation

struct ContentWebView: View {
    var model: BrowserViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    private var visibleGoForward:Bool{
        horizontalSizeClass == .regular || model.canGoForward
    }
    
    var body: some View {
        PreviewWebViewRepresentable(webView: model.webView)
            .ignoresSafeArea(.container,edges: .top)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!model.canGoBack)
                    
                    if visibleGoForward{
                        Button {
                            model.goForward()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!model.canGoForward)
                    }
                }
            }
            .animation(.default,value:visibleGoForward)
            .navigationTitle(model.currentURL?.host() ?? "")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .overlay(alignment:.top){
                if model.isShowingProgress{
                    ProgressView(value: model.estimatedProgress, total: 1.0)
#if os(macOS)
                        .progressViewStyle(CustomProgressViewStyle())
#else
                        .progressViewStyle(.linear)
#endif
                        .controlSize(.small)
                        .animation(.default,value:model.estimatedProgress)
                }
            }
            .animation(.default,value:model.isShowingProgress)
            .background(model.underPageBackgroundColor ?? .clear)
    }
}
struct CustomProgressViewStyle: ProgressViewStyle {
    var borderSize:CGFloat = 2
    
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .foregroundStyle(.secondary.opacity(0.3))
                UnevenRoundedRectangle(
                  topLeadingRadius: 0,
                  bottomLeadingRadius: 0,
                  bottomTrailingRadius: borderSize / 2,
                  topTrailingRadius: borderSize / 2,
                  style: .continuous
                )
                .foregroundStyle(.blue)
                .frame(width: geometry.size.width * CGFloat(configuration.fractionCompleted ?? 0))
            }
            .frame(height: borderSize)
        }
    }
}
