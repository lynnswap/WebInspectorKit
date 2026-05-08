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
    private var displayTask: Task<Void, Never>?
    private var displayGeneration: UInt64 = 0
    private weak var body: NetworkBody?
    private var syntaxKind: NetworkEntry.BodySyntaxKind = .plainText
    private var isURLEncodedForm = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureSyntaxView()
    }

    isolated deinit {
        displayTask?.cancel()
        observationScope.cancelAll()
    }

    func display(
        body: NetworkBody?,
        syntaxKind: NetworkEntry.BodySyntaxKind,
        isURLEncodedForm: Bool
    ) {
        self.body = body
        self.syntaxKind = syntaxKind
        self.isURLEncodedForm = isURLEncodedForm
        startObserving(body: body)
        requestBodyDisplayUpdate()
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
                    self.requestBodyDisplayUpdate()
                }
                .store(in: observationScope)
            }
        }
    }

    private func requestBodyDisplayUpdate() {
        displayTask?.cancel()
        displayGeneration &+= 1
        let generation = displayGeneration
        let body = body
        let bodyKind = body?.kind
        let fullText = body?.full
        let previewText = body?.preview
        let summaryText = body?.summary
        let isBase64Encoded = body?.isBase64Encoded ?? false
        let formEntries = body?.formEntries ?? []
        let syntaxKind = syntaxKind
        let isURLEncodedForm = isURLEncodedForm
        let unavailableText = wiLocalized("network.body.unavailable", default: "Body unavailable")
        let fetchingText = wiLocalized("network.body.fetching", default: "Fetching body...")
        let isFetching: Bool
        let fetchErrorText: String?
        switch body?.fetchState {
        case .fetching:
            isFetching = true
            fetchErrorText = nil
        case .failed(let error):
            isFetching = false
            fetchErrorText = error.localizedDescriptionText
        default:
            isFetching = false
            fetchErrorText = nil
        }

        displayTask = Task(priority: .userInitiated) {
            [
                weak self,
                generation,
                bodyKind,
                fullText,
                previewText,
                summaryText,
                isBase64Encoded,
                formEntries,
                isFetching,
                fetchErrorText,
                syntaxKind,
                isURLEncodedForm,
                unavailableText,
                fetchingText,
            ] in
            let workerTask = Task.detached(priority: .userInitiated) {
                if isFetching {
                    return (text: fetchingText, language: SyntaxLanguage.json, usesPlainTextTheme: true)
                }

                let decoded = decodedV2NetworkBodyText(
                    kind: bodyKind,
                    fullText: fullText,
                    previewText: previewText,
                    isBase64Encoded: isBase64Encoded
                )
                let contentText = decoded ?? fullText ?? previewText
                let formText = formattedV2NetworkBodyFormText(
                    kind: bodyKind,
                    isURLEncodedForm: isURLEncodedForm,
                    formEntries: formEntries,
                    contentText: contentText
                )
                let prettyJSON = formText == nil ? prettyPrintedV2NetworkBodyJSON(from: contentText) : nil
                let displayText = formText
                    ?? prettyJSON
                    ?? contentText
                    ?? summaryText
                    ?? unavailableText
                let text = if let fetchErrorText {
                    displayText + "\n\n" + fetchErrorText
                } else {
                    displayText
                }
                let syntax = v2NetworkBodySyntax(
                    kind: bodyKind,
                    syntaxKind: syntaxKind,
                    isURLEncodedForm: isURLEncodedForm,
                    contentText: contentText,
                    didPrettyPrintJSON: prettyJSON != nil
                )
                return (text: text, language: syntax.language, usesPlainTextTheme: syntax.usesPlainTextTheme)
            }
            let display = await withTaskCancellationHandler {
                await workerTask.value
            } onCancel: {
                workerTask.cancel()
            }

            guard
                Task.isCancelled == false,
                let self,
                self.displayGeneration == generation
            else {
                return
            }
            self.applyBodyDisplay(
                text: display.text,
                language: display.language,
                usesPlainTextTheme: display.usesPlainTextTheme
            )
        }
    }

    private func applyBodyDisplay(
        text: String,
        language: SyntaxLanguage,
        usesPlainTextTheme: Bool
    ) {
        if syntaxModel.language != language {
            syntaxModel.language = language
        }
        let colorTheme: SyntaxEditorColorTheme = usesPlainTextTheme ? .webInspectorPlainText : .xcode
        if syntaxModel.colorTheme != colorTheme {
            syntaxModel.colorTheme = colorTheme
        }
        if syntaxModel.text != text {
            syntaxModel.text = text
        }
    }
}

private func decodedV2NetworkBodyText(
    kind: NetworkBody.Kind?,
    fullText: String?,
    previewText: String?,
    isBase64Encoded: Bool
) -> String? {
    guard kind != .binary else {
        return nil
    }
    guard let candidate = fullText ?? previewText else {
        return nil
    }
    guard isBase64Encoded else {
        return candidate
    }
    guard let data = Data(base64Encoded: candidate) else {
        return nil
    }
    if let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return String(decoding: data, as: UTF8.self)
}

private func formattedV2NetworkBodyFormText(
    kind: NetworkBody.Kind?,
    isURLEncodedForm: Bool,
    formEntries: [NetworkBody.FormEntry],
    contentText: String?
) -> String? {
    guard kind == .form || isURLEncodedForm else {
        return nil
    }
    if formEntries.isEmpty == false {
        return formEntries.map(v2NetworkBodyFormEntryLine).joined(separator: "\n")
    }
    guard let contentText else {
        return nil
    }
    return formattedV2NetworkURLEncodedFormText(from: contentText)
}

private func v2NetworkBodyFormEntryLine(_ entry: NetworkBody.FormEntry) -> String {
    let value: String
    if entry.isFile, let fileName = entry.fileName, fileName.isEmpty == false {
        value = "<file \(fileName)>"
    } else {
        value = entry.value
    }
    return "\(entry.name)=\(value)"
}

private func formattedV2NetworkURLEncodedFormText(from text: String) -> String? {
    guard text.isEmpty == false, text.contains("=") else {
        return nil
    }

    var lines: [String] = []
    for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.isEmpty == false else {
            continue
        }
        guard let name = decodedV2NetworkFormComponent(String(parts[0])) else {
            return nil
        }
        let value: String
        if parts.count > 1 {
            guard let decodedValue = decodedV2NetworkFormComponent(String(parts[1])) else {
                return nil
            }
            value = decodedValue
        } else {
            value = ""
        }
        lines.append("\(name)=\(value)")
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

private func decodedV2NetworkFormComponent(_ component: String) -> String? {
    component
        .replacingOccurrences(of: "+", with: " ")
        .removingPercentEncoding
}

private func prettyPrintedV2NetworkBodyJSON(from text: String?) -> String? {
    guard let text, let data = text.data(using: .utf8) else {
        return nil
    }
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        return nil
    }
    guard JSONSerialization.isValidJSONObject(object) else {
        return nil
    }
    guard
        let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
        let pretty = String(data: prettyData, encoding: .utf8)
    else {
        return nil
    }
    return pretty
}

private func v2NetworkBodySyntax(
    kind: NetworkBody.Kind?,
    syntaxKind: NetworkEntry.BodySyntaxKind,
    isURLEncodedForm: Bool,
    contentText: String?,
    didPrettyPrintJSON: Bool
) -> (language: SyntaxLanguage, usesPlainTextTheme: Bool) {
    if kind == .form || isURLEncodedForm {
        return (.json, true)
    }
    if didPrettyPrintJSON {
        return (.json, false)
    }
    if contentText.flatMap(prettyPrintedV2NetworkBodyJSON(from:)) != nil {
        return (.json, false)
    }
    return syntaxKind.syntax
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

private extension NetworkEntry.BodySyntaxKind {
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
