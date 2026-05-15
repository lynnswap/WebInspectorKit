#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorUI
import UIKit
import WebInspectorCore

@MainActor
final class NetworkBodyViewController: UIViewController {
    private let syntaxModel = SyntaxEditorModel(
        text: "",
        language: .json,
        isEditable: false,
        lineWrappingEnabled: true,
        colorTheme: .v2WebInspectorPlainText
    )
    private lazy var syntaxView = SyntaxEditorView(model: syntaxModel)
    private let observationScope = ObservationScope()
    private weak var body: NetworkBody?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureSyntaxView()
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    func display(body: NetworkBody?) {
        self.body = body
        startObserving(body: body)
        renderBody()
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
        syntaxView.accessibilityIdentifier = "WebInspector.Network.BodyView"
        view.addSubview(syntaxView)

        NSLayoutConstraint.activate([
            syntaxView.topAnchor.constraint(equalTo: view.topAnchor),
            syntaxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            syntaxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            syntaxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func startObserving(body: NetworkBody?) {
        observationScope.update {
            if let body {
                body.observe(
                    [
                        \.textRepresentation,
                        \.textRepresentationSyntaxKind,
                        \.fetchState,
                    ]
                ) { [weak self, weak body] in
                    guard let self, body === self.body else {
                        return
                    }
                    self.renderBody()
                }
                .store(in: observationScope)
            }
        }
    }

    private func renderBody() {
        let displayText: String
        let syntaxKind: NetworkBodySyntaxKind
        guard let body else {
            applyBodyDisplay(
                text: webInspectorLocalized("network.body.unavailable", default: "Body unavailable"),
                syntaxKind: .plainText
            )
            return
        }

        switch body.fetchState {
        case .available:
            displayText = webInspectorLocalized("network.body.available", default: "Body available")
            syntaxKind = .plainText
        case .fetching:
            displayText = webInspectorLocalized("network.body.fetching", default: "Fetching body...")
            syntaxKind = .plainText
        case .loaded:
            displayText = body.textRepresentation
                ?? webInspectorLocalized("network.body.unavailable", default: "Body unavailable")
            syntaxKind = body.textRepresentationSyntaxKind
        case .failed(let error):
            let text = body.textRepresentation
                ?? webInspectorLocalized("network.body.unavailable", default: "Body unavailable")
            displayText = text + "\n\n" + localizedDescription(for: error)
            syntaxKind = body.textRepresentationSyntaxKind
        }

        applyBodyDisplay(text: displayText, syntaxKind: syntaxKind)
    }

    private func localizedDescription(for error: NetworkBodyFetchError) -> String {
        switch error {
        case .unavailable:
            webInspectorLocalized("network.body.fetch.error.unavailable", default: "Body unavailable")
        case .decodeFailed:
            webInspectorLocalized("network.body.fetch.error.decode_failed", default: "Body decode failed")
        case .unknown(let message):
            message ?? webInspectorLocalized("network.body.fetch.error.unknown", default: "Body fetch failed")
        }
    }

    private func applyBodyDisplay(
        text: String,
        syntaxKind: NetworkBodySyntaxKind
    ) {
        let syntax = syntaxKind.syntax
        if syntaxModel.language != syntax.language {
            syntaxModel.language = syntax.language
        }
        let colorTheme: SyntaxEditorColorTheme = syntax.usesPlainTextTheme ? .v2WebInspectorPlainText : .xcode
        if syntaxModel.colorTheme != colorTheme {
            syntaxModel.colorTheme = colorTheme
        }
        if syntaxModel.text != text {
            syntaxModel.text = text
        }
    }
}

@MainActor
extension SyntaxEditorColorTheme {
    static let v2WebInspectorPlainText = SyntaxEditorColorTheme(
        baseForeground: .label,
        bracketBackground: .clear,
        comment: .label,
        string: .label,
        keyword: .label,
        number: .label,
        function: .label,
        type: .label,
        constant: .label,
        variable: .label,
        punctuation: .label
    )
}

private extension NetworkBodySyntaxKind {
    var syntax: (language: SyntaxLanguage, usesPlainTextTheme: Bool) {
        switch self {
        case .plainText:
            (.json, true)
        case .json:
            (.json, false)
        case .html:
            (.html, false)
        case .xml:
            (.xml, false)
        case .css:
            (.css, false)
        case .javascript:
            (.javascript, false)
        }
    }
}

#if DEBUG
extension NetworkBodyViewController {
    var syntaxViewForTesting: SyntaxEditorView {
        loadViewIfNeeded()
        return syntaxView
    }
}
#endif
#endif
