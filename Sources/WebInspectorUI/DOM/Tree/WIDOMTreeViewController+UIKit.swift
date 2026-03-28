import WebKit
import WebInspectorRuntime
import ObservationBridge

#if canImport(UIKit)
import UIKit

@MainActor
public final class WIDOMTreeViewController: UIViewController {
    private let inspector: WIDOMModel
    private var observationHandles: Set<ObservationHandle> = []

    public init(inspector: WIDOMModel) {
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

        let inspectorWebView = inspector.makeInspectorWebView()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inspectorWebView)

        NSLayoutConstraint.activate([
            inspectorWebView.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        observeState()
        updateErrorPresentation(errorMessage: inspector.errorMessage)
    }

    private func observeState() {
        inspector.observe(
            \.errorMessage,
            options: [.removeDuplicates]
        ) { [weak self] newErrorMessage in
            self?.updateErrorPresentation(errorMessage: newErrorMessage)
        }
        .store(in: &observationHandles)
    }

    private func updateErrorPresentation(errorMessage: String?) {
        if let errorMessage, !errorMessage.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = errorMessage
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }
}

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
