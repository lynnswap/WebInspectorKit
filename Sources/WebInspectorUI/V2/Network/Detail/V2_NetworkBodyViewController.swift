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
        syntaxView.accessibilityIdentifier = "V2.Network.BodyView"
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
        let unavailableText = wiLocalized("network.body.unavailable", default: "Body unavailable")
        let fetchingText = wiLocalized("network.body.fetching", default: "Fetching body...")
        let displayText: String
        let syntaxKind: NetworkBodySyntaxKind
        guard let body else {
            applyBodyDisplay(text: unavailableText, syntaxKind: .plainText)
            return
        }

        switch body.fetchState {
        case .fetching:
            displayText = fetchingText
            syntaxKind = .plainText
        case .failed(let error):
            displayText = (body.textRepresentation ?? unavailableText)
                + "\n\n"
                + error.localizedDescriptionText
            syntaxKind = body.textRepresentationSyntaxKind
        default:
            displayText = body.textRepresentation ?? unavailableText
            syntaxKind = body.textRepresentationSyntaxKind
        }

        applyBodyDisplay(text: displayText, syntaxKind: syntaxKind)
    }

    private func applyBodyDisplay(
        text: String,
        syntaxKind: NetworkBodySyntaxKind
    ) {
        let syntax = syntaxKind.syntax
        let language = syntax.language
        if syntaxModel.language != language {
            syntaxModel.language = language
        }
        let colorTheme: SyntaxEditorColorTheme = syntax.usesPlainTextTheme ? .webInspectorPlainText : .xcode
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
    static let webInspectorPlainText = SyntaxEditorColorTheme(
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
extension V2_NetworkBodyViewController {
    var syntaxViewForTesting: SyntaxEditorView {
        loadViewIfNeeded()
        return syntaxView
    }
}
#endif
#endif
