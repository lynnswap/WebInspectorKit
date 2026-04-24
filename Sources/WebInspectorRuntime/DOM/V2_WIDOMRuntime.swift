import Observation
import WebKit
import WebInspectorEngine
import WebInspectorTransport

@MainActor
@Observable
public final class V2_WIDOMRuntime {
    private let inspector: WIDOMInspector
    @ObservationIgnored private var domTreeWebView: WKWebView?

    public let document: DOMDocumentModel

    public convenience init(configuration: DOMConfiguration = .init()) {
        self.init(
            configuration: configuration,
            sharedTransport: WISharedInspectorTransport()
        )
    }

    package init(
        configuration: DOMConfiguration,
        sharedTransport: WISharedInspectorTransport
    ) {
        let inspector = WIDOMInspector(
            configuration: configuration,
            sharedTransport: sharedTransport
        )
        self.inspector = inspector
        self.document = inspector.document
    }

    public func attach(to webView: WKWebView) async {
        await inspector.attach(to: webView)
    }

    public func detach() async {
        domTreeWebView = nil
        await inspector.detach()
    }

    package func treeWebViewForPresentation() -> WKWebView {
        if let domTreeWebView {
            return domTreeWebView
        }

        let domTreeWebView = inspector.inspectorWebViewForPresentation()
        self.domTreeWebView = domTreeWebView
        return domTreeWebView
    }
}
