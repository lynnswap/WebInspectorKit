import OSLog
import WebKit
import WebInspectorKitCore

private let domTreeViewLogger = Logger(subsystem: "WebInspectorKit", category: "DOMTreeView")

@MainActor
final class InspectorWebView: WKWebView {
    convenience init() {
        self.init(frame: .zero, configuration: Self.makeDefaultConfiguration())
    }
    
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        Self.installDOMTreeViewScriptsIfNeeded(on: configuration.userContentController)
        applyInspectorDefaults()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private static func makeDefaultConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.writingToolsBehavior = .none
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController = makeInspectorContentController()
        return configuration
    }

    private static func makeInspectorContentController() -> WKUserContentController {
        let controller = WKUserContentController()
        installDOMTreeViewScriptsIfNeeded(on: controller)
        return controller
    }

    private static func installDOMTreeViewScriptsIfNeeded(on controller: WKUserContentController) {
        let existingSources = Set(controller.userScripts.map(\.source))
        do {
            let scriptSource = try WebInspectorScripts.domTreeView()
            if existingSources.contains(scriptSource) {
                return
            }
            controller.addUserScript(
                WKUserScript(
                    source: scriptSource,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        } catch {
            domTreeViewLogger.error("missing DOMTreeView script: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func applyInspectorDefaults() {
#if DEBUG
        isInspectable = true
#endif
        
#if canImport(UIKit)
        scrollView.isScrollEnabled = true
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        scrollView.contentInset = .zero
        scrollView.scrollIndicatorInsets = .zero
        scrollView.clipsToBounds = false
        clipsToBounds = false
#endif
    }
    
#if canImport(UIKit)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        
        guard builder.system == .context else { return }
        
        builder.remove(menu: .lookup)
        builder.remove(menu: .share)
    
    }
#endif
}
