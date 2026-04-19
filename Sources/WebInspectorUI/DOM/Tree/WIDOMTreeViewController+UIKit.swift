import WebKit
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
public final class WIDOMTreeViewController: UIViewController {
    private let inspector: WIDOMInspector
    private let inspectorWebViewContainer = UIView()
    private weak var attachedInspectorWebView: WKWebView?
    private var inspectorWebViewConstraints: [NSLayoutConstraint] = []
    private var isInspectorWebViewActive = false
    private var managesInspectorWebViewExternally = false

    public init(inspector: WIDOMInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = nil

        inspectorWebViewContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inspectorWebViewContainer)

        NSLayoutConstraint.activate([
            inspectorWebViewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorWebViewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebViewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebViewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        applyInspectorWebViewActivityIfNeeded()
    }

    func setInspectorWebViewActive(_ active: Bool) {
        guard isInspectorWebViewActive != active else {
            applyInspectorWebViewActivityIfNeeded()
            return
        }

        isInspectorWebViewActive = active
        applyInspectorWebViewActivityIfNeeded()
    }

    func setManagesInspectorWebViewExternally(_ manages: Bool) {
        guard managesInspectorWebViewExternally != manages else {
            return
        }
        managesInspectorWebViewExternally = manages
        applyInspectorWebViewActivityIfNeeded()
    }

    private func applyInspectorWebViewActivityIfNeeded() {
        guard isViewLoaded else {
            return
        }

        if managesInspectorWebViewExternally == false || isInspectorWebViewActive {
            attachInspectorWebViewIfNeeded()
        } else {
            detachInspectorWebViewIfNeeded()
        }
    }

    private func attachInspectorWebViewIfNeeded() {
        let inspectorWebView = inspector.makeInspectorWebView()
        guard inspectorWebView.superview !== inspectorWebViewContainer else {
            attachedInspectorWebView = inspectorWebView
            return
        }

        NSLayoutConstraint.deactivate(inspectorWebViewConstraints)
        inspectorWebViewConstraints.removeAll(keepingCapacity: true)
        inspectorWebView.removeFromSuperview()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        inspectorWebViewContainer.addSubview(inspectorWebView)
        let constraints = [
            inspectorWebView.topAnchor.constraint(equalTo: inspectorWebViewContainer.topAnchor),
            inspectorWebView.leadingAnchor.constraint(equalTo: inspectorWebViewContainer.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: inspectorWebViewContainer.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: inspectorWebViewContainer.bottomAnchor)
        ]
        NSLayoutConstraint.activate(constraints)
        inspectorWebViewConstraints = constraints
        attachedInspectorWebView = inspectorWebView
    }

    private func detachInspectorWebViewIfNeeded() {
        guard let inspectorWebView = attachedInspectorWebView else {
            NSLayoutConstraint.deactivate(inspectorWebViewConstraints)
            inspectorWebViewConstraints.removeAll(keepingCapacity: true)
            return
        }
        guard inspectorWebView.superview === inspectorWebViewContainer else {
            attachedInspectorWebView = nil
            NSLayoutConstraint.deactivate(inspectorWebViewConstraints)
            inspectorWebViewConstraints.removeAll(keepingCapacity: true)
            return
        }

        NSLayoutConstraint.deactivate(inspectorWebViewConstraints)
        inspectorWebViewConstraints.removeAll(keepingCapacity: true)
        inspectorWebView.removeFromSuperview()
        attachedInspectorWebView = nil
    }
}

#if DEBUG
extension WIDOMTreeViewController {
    func frontendIsReadyForTesting() async -> Bool {
        guard let attachedInspectorWebView,
              attachedInspectorWebView.superview === inspectorWebViewContainer
        else {
            return false
        }
        let rawValue = try? await attachedInspectorWebView.callAsyncJavaScriptCompat(
            "return Boolean(window.webInspectorDOMFrontend && document.getElementById('dom-tree'));",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        if let value = rawValue as? Bool {
            return value
        }
        if let value = rawValue as? NSNumber {
            return value.boolValue
        }
        return false
    }

    func treeTextContentForTesting() async -> String? {
        guard let attachedInspectorWebView,
              attachedInspectorWebView.superview === inspectorWebViewContainer
        else {
            return nil
        }
        let rawValue = try? await attachedInspectorWebView.callAsyncJavaScriptCompat(
            "return document.getElementById('dom-tree')?.textContent ?? null;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        return rawValue as? String
    }

    func selectedNodeTextForTesting() async -> String? {
        guard let attachedInspectorWebView,
              attachedInspectorWebView.superview === inspectorWebViewContainer
        else {
            return nil
        }
        let rawValue = try? await attachedInspectorWebView.callAsyncJavaScriptCompat(
            "return document.querySelector('.tree-node.is-selected .tree-node__row')?.textContent ?? null;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        return rawValue as? String
    }

    var isInspectorWebViewAttachedForTesting: Bool {
        guard let attachedInspectorWebView else {
            return false
        }
        return attachedInspectorWebView.superview === inspectorWebViewContainer
    }

    func selectedNodeIDForTesting() async -> Int? {
        guard let attachedInspectorWebView,
              attachedInspectorWebView.superview === inspectorWebViewContainer
        else {
            return nil
        }
        let rawValue = try? await attachedInspectorWebView.callAsyncJavaScriptCompat(
            """
            const selectedNode = document.querySelector('.tree-node.is-selected');
            return selectedNode ? Number(selectedNode.dataset.nodeId) : null;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        if let value = rawValue as? Int {
            return value
        }
        if let value = rawValue as? NSNumber {
            return value.intValue
        }
        return nil
    }
}
#endif

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Tree (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMTreeViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected)
            )
        )
    }
}
#endif


#endif
