#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorUI
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class V2_NetworkBodyViewController: UIViewController {
    private let syntaxModel = SyntaxEditorModel(
        text: "",
        language: .json,
        isEditable: false,
        lineWrappingEnabled: true,
        colorTheme: .webInspectorPlainText
    )
    private lazy var syntaxView = SyntaxEditorView(model: syntaxModel)
    private let observationScope = ObservationScope()
    private var renderTask: Task<Void, Never>?
    private var renderGeneration: UInt64 = 0
    private weak var entry: NetworkEntry?
    private weak var body: NetworkBody?
    private var role: NetworkBody.Role = .response

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureSyntaxView()
    }

    isolated deinit {
        renderTask?.cancel()
        observationScope.cancelAll()
    }

    func display(entry: NetworkEntry?, body: NetworkBody?, role: NetworkBody.Role) {
        self.entry = entry
        self.body = body
        self.role = role
        startObserving(entry: entry, body: body)
        requestRenderModelUpdate()
    }

    private func configureSyntaxView() {
        syntaxView.translatesAutoresizingMaskIntoConstraints = false
        syntaxView.isEditable = false
        syntaxView.isSelectable = true
        syntaxView.isScrollEnabled = true
        syntaxView.alwaysBounceVertical = true
        syntaxView.backgroundColor = .clear
        syntaxView.contentInsetAdjustmentBehavior = .automatic
        syntaxView.keyboardDismissMode = .onDrag
        syntaxView.accessibilityIdentifier = "V2.Network.BodyView"
        view.addSubview(syntaxView)

        NSLayoutConstraint.activate([
            syntaxView.topAnchor.constraint(equalTo: view.topAnchor),
            syntaxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            syntaxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            syntaxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func startObserving(entry: NetworkEntry?, body: NetworkBody?) {
        observationScope.update {
            if let entry {
                entry.observe([\.url, \.mimeType, \.requestHeaders, \.responseHeaders]) { [weak self, weak entry] in
                    guard let self, entry === self.entry else {
                        return
                    }
                    self.requestRenderModelUpdate()
                }
                .store(in: observationScope)
            }

            if let body {
                body.observe(
                    [
                        \.kind,
                        \.preview,
                        \.full,
                        \.summary,
                        \.isBase64Encoded,
                        \.formEntries,
                        \.fetchState,
                    ]
                ) { [weak self, weak body] in
                    guard let self, body === self.body else {
                        return
                    }
                    self.requestRenderModelUpdate()
                }
                .store(in: observationScope)
            }
        }
    }

    private func requestRenderModelUpdate() {
        renderTask?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        let input = V2_NetworkBodyRenderModel.Input(
            entry: entry,
            body: body,
            role: role,
            unavailableText: wiLocalized("network.body.unavailable", default: "Body unavailable"),
            fetchingText: wiLocalized("network.body.fetching", default: "Fetching body...")
        )

        renderTask = Task(priority: .userInitiated) { [weak self, generation, input] in
            let workerTask = Task.detached(priority: .userInitiated) {
                V2_NetworkBodyRenderModel.make(from: input)
            }
            let model = await withTaskCancellationHandler {
                await workerTask.value
            } onCancel: {
                workerTask.cancel()
            }

            guard
                Task.isCancelled == false,
                let self,
                self.renderGeneration == generation
            else {
                return
            }
            self.applyRenderModel(model)
        }
    }

    private func applyRenderModel(_ renderModel: V2_NetworkBodyRenderModel) {
        let language = renderModel.syntaxStyle.language
        if syntaxModel.language != language {
            syntaxModel.language = language
        }
        let colorTheme = renderModel.syntaxStyle.colorTheme
        if syntaxModel.colorTheme != colorTheme {
            syntaxModel.colorTheme = colorTheme
        }
        if syntaxModel.text != renderModel.text {
            syntaxModel.text = renderModel.text
        }
    }
}

#if DEBUG
extension V2_NetworkBodyViewController {
    var syntaxViewForTesting: SyntaxEditorView {
        loadViewIfNeeded()
        return syntaxView
    }
}
#endif
#endif
