import OSLog
import WebKit

private let domTreeViewLogger = Logger(subsystem: "WebInspectorKit", category: "DOMTreeView")

@MainActor
final class WIWebView: WKWebView {
    convenience init() {
        self.init(frame: .zero, configuration: Self.makeDefaultConfiguration())
    }
    
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
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
        let scripts = DOMTreeViewScriptSource.userScripts()
        for script in scripts {
            controller.addUserScript(script)
        }
        return controller
    }
    
    private func applyInspectorDefaults() {
#if DEBUG
        isInspectable = true
#endif
        
#if canImport(UIKit)
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = true
        scrollView.alwaysBounceVertical = true
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

private enum DOMTreeViewScriptSource {
    private static let scriptNames = [
        "DOMTreeState",
        "DOMTreeUtilities",
        "DOMTreeProtocol",
        "DOMTreeModel",
        "DOMTreeViewSupport",
        "DOMTreeUpdates",
        "DOMTreeSnapshot",
        "DOMTreeView"
    ]

    @MainActor
    static func userScripts() -> [WKUserScript] {
        scriptNames.compactMap { name in
            guard let source = WIScriptBundle.source(named: name) else {
                domTreeViewLogger.error("missing DOMTreeView script: \(name, privacy: .public)")
                return nil
            }
            return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        }
    }
}
