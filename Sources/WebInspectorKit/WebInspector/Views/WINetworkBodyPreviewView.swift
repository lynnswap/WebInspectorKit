import Foundation
import SwiftUI
import WebKit

private struct WINetworkDOMPreviewPayload: Equatable {
    let html: String
    let baseURL: URL?
    let mimeType: String
}

struct WINetworkBodyPreviewView: View {
    private enum PreviewMode: String, CaseIterable, Identifiable {
        case text
        case json
        case dom

        var id: String { rawValue }

        var localizedTitle: LocalizedStringResource {
            switch self {
            case .text:
                return LocalizedStringResource("network.body.preview.mode.text", bundle: .module)
            case .json:
                return LocalizedStringResource("network.body.preview.mode.json", bundle: .module)
            case .dom:
                return LocalizedStringResource("network.body.preview.mode.dom", bundle: .module)
            }
        }
    }

    private struct PreviewData {
        let text: String?
        let jsonNodes: [WINetworkJSONNode]?
        let domPayload: WINetworkDOMPreviewPayload?

        var availableModes: [PreviewMode] {
            var modes: [PreviewMode] = [.text]
            if jsonNodes != nil {
                modes.append(.json)
            }
            if domPayload != nil {
                modes.append(.dom)
            }
            return modes
        }
    }

    let entry: WINetworkEntry
    let viewModel: WINetworkViewModel
    let bodyState: WINetworkBody

    @State private var selectedMode: PreviewMode = .text

    var body: some View {
        let previewData = makePreviewData()

        VStack(spacing: 12) {
            if previewData.availableModes.count > 1 {
                Picker("network.body.preview", selection: $selectedMode) {
                    ForEach(previewData.availableModes) { mode in
                        Text(mode.localizedTitle)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            if bodyState.fetchState != .full {
                fetchButton
                    .padding(.horizontal)
            }

            if case let .failed(error) = bodyState.fetchState {
                Text(error.localizedResource)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Group {
                switch selectedMode {
                case .text:
                    WINetworkTextPreviewView(text: previewData.text, summary: bodyState.summary)
                case .json:
                    WINetworkJSONPreviewView(nodes: previewData.jsonNodes ?? [])
                case .dom:
                    if let payload = previewData.domPayload {
                        WINetworkDOMPreviewView(payload: payload)
                    } else {
                        WINetworkTextPreviewView(text: nil, summary: bodyState.summary)
                    }
                }
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(previewTitle)
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear {
            selectedMode = preferredMode(from: previewData.availableModes)
        }
        .onChange(of: previewData.availableModes) { _, newModes in
            if newModes.contains(selectedMode) {
                return
            }
            selectedMode = preferredMode(from: newModes)
        }
    }

    private var previewTitle: LocalizedStringResource {
        switch bodyState.role {
        case .request:
            return LocalizedStringResource("network.section.body.request", bundle: .module)
        case .response:
            return LocalizedStringResource("network.section.body.response", bundle: .module)
        }
    }

    private var fetchButton: some View {
        Button {
            Task {
                switch bodyState.role {
                case .request:
                    await viewModel.fetchRequestBody(for: entry)
                case .response:
                    await viewModel.fetchResponseBody(for: entry)
                }
            }
        } label: {
            if bodyState.fetchState == .fetching {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text("network.body.fetch")
                    .padding(.horizontal)
            }
        }
        .fetchButtonStyle()
        .font(.footnote)
    }

    private func preferredMode(from modes: [PreviewMode]) -> PreviewMode {
        if modes.contains(.json) {
            return .json
        }
        if modes.contains(.dom) {
            return .dom
        }
        return .text
    }

    private func makePreviewData() -> PreviewData {
        let decoded = decodedText(from: bodyState)
        let text = decoded ?? bodyState.full ?? bodyState.preview ?? bodyState.summary
        let jsonNodes = decoded.flatMap(WINetworkJSONNode.nodes(from:))
        let domPayload = decoded.flatMap { makeDOMPreviewPayload(text: $0) }
        return PreviewData(text: text, jsonNodes: jsonNodes, domPayload: domPayload)
    }

    private func decodedText(from body: WINetworkBody) -> String? {
        guard body.kind != .binary else {
            return nil
        }
        guard let candidate = body.full ?? body.preview else {
            return nil
        }
        guard body.isBase64Encoded else {
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

    private func makeDOMPreviewPayload(text: String) -> WINetworkDOMPreviewPayload? {
        let mimeType = resolveMimeType(for: bodyState.role)
        let normalized = normalizeMIMEType(mimeType)
        let baseURL = URL(string: entry.url)

        if let normalized, isDOMMIMEType(normalized) {
            return WINetworkDOMPreviewPayload(html: text, baseURL: baseURL, mimeType: normalized)
        }

        if looksLikeMarkup(text) {
            return WINetworkDOMPreviewPayload(html: text, baseURL: baseURL, mimeType: "text/html")
        }

        return nil
    }

    private func resolveMimeType(for role: WINetworkBody.Role) -> String? {
        switch role {
        case .request:
            return entry.requestHeaders["content-type"]
        case .response:
            return entry.mimeType ?? entry.responseHeaders["content-type"]
        }
    }

    private func normalizeMIMEType(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
        let normalized = trimmed?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else {
            return nil
        }

        if normalized.hasSuffix("/html") || normalized.hasSuffix("+html") {
            return "text/html"
        }
        if normalized.hasSuffix("/xml") || normalized.hasSuffix("+xml") {
            if normalized != "application/xhtml+xml" && normalized != "image/svg+xml" {
                return "application/xml"
            }
        }
        if normalized.hasSuffix("/xhtml") || normalized.hasSuffix("+xhtml") {
            return "application/xhtml+xml"
        }
        if normalized.hasSuffix("/svg") || normalized.hasSuffix("+svg") {
            return "image/svg+xml"
        }
        return normalized
    }

    private func isDOMMIMEType(_ mimeType: String) -> Bool {
        switch mimeType {
        case "text/html",
             "application/xhtml+xml",
             "application/xml",
             "text/xml",
             "image/svg+xml":
            return true
        default:
            return false
        }
    }

    private func looksLikeMarkup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<?xml") {
            return true
        }
        if lowered.contains("<html") || lowered.contains("<svg") {
            return true
        }
        return false
    }
}

private struct WINetworkTextPreviewView: View {
    let text: String?
    let summary: String?

    var body: some View {
        ScrollView {
            if let text {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
            } else if let summary {
                Text(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
            } else {
                Text("network.body.unavailable")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
            }
        }
    }
}

private struct WINetworkJSONPreviewView: View {
    let nodes: [WINetworkJSONNode]

    var body: some View {
        if nodes.isEmpty {
            WINetworkTextPreviewView(text: nil, summary: nil)
        } else {
            List {
                OutlineGroup(nodes, children: \.children) { node in
                    WINetworkJSONRowView(node: node)
                        .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct WINetworkJSONRowView: View {
    let node: WINetworkJSONNode

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            WINetworkJSONTypeBadge(symbol: badgeSymbol, tint: badgeTint)
            HStack(spacing: 4) {
                if !node.key.isEmpty {
                    Text(node.key)
                        .foregroundStyle(node.isIndex ? .secondary : .primary)
                }
                if !node.key.isEmpty {
                    Text(":")
                        .foregroundStyle(.secondary)
                }
                Text(valueText)
                    .foregroundStyle(valueColor)
            }
        }
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }

    private var valueText: String {
        switch node.displayKind {
        case .object:
            return "Object"
        case .array(let count):
            return "Array (\(count))"
        case .string(let value):
            return "\"\(truncate(value))\""
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private var valueColor: Color {
        switch node.displayKind {
        case .object, .array:
            return .secondary
        case .string:
            return .red
        case .number:
            return .blue
        case .bool:
            return .purple
        case .null:
            return .secondary
        }
    }

    private var badgeSymbol: String {
        switch node.displayKind {
        case .object:
            return "O"
        case .array:
            return "A"
        case .string:
            return "S"
        case .number:
            return "N"
        case .bool:
            return "B"
        case .null:
            return "0"
        }
    }

    private var badgeTint: Color {
        switch node.displayKind {
        case .object, .array:
            return .yellow
        case .string:
            return .red
        case .number:
            return .blue
        case .bool:
            return .purple
        case .null:
            return .secondary
        }
    }

    private func truncate(_ value: String, limit: Int = 200) -> String {
        guard value.count > limit else {
            return value
        }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "..."
    }
}

private struct WINetworkJSONTypeBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Text(symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.6), lineWidth: 1)
            )
    }
}

private struct WINetworkDOMPreviewView: View {
    let payload: WINetworkDOMPreviewPayload

    @State private var controller: WINetworkDOMPreviewController

    init(payload: WINetworkDOMPreviewPayload) {
        self.payload = payload
        _controller = State(initialValue: WINetworkDOMPreviewController(payload: payload))
    }

    var body: some View {
        ZStack {
            WIDOMView(viewModel: controller.viewModel)
            WINetworkHiddenWebView(webView: controller.pageWebView)
                .frame(width: 0, height: 0)
                .opacity(0.001)
                .accessibilityHidden(true)
        }
        .onChange(of: payload) { _, newValue in
            controller.update(payload: newValue)
        }
        .onDisappear {
            controller.detach()
        }
    }
}

@MainActor
private final class WINetworkDOMPreviewController: NSObject {
    let viewModel: WIDOMViewModel
    let pageWebView: WKWebView

    private var lastPayload: WINetworkDOMPreviewPayload?

    init(payload: WINetworkDOMPreviewPayload) {
        self.viewModel = WIDOMViewModel()
        self.pageWebView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
        super.init()
        pageWebView.navigationDelegate = self
        viewModel.attach(to: pageWebView)
        update(payload: payload)
    }

    func update(payload: WINetworkDOMPreviewPayload) {
        guard payload != lastPayload else {
            return
        }
        lastPayload = payload
        pageWebView.loadHTMLString(payload.html, baseURL: payload.baseURL)
    }

    func detach() {
        viewModel.detach()
        pageWebView.navigationDelegate = nil
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}

extension WINetworkDOMPreviewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await viewModel.reloadInspector(preserveState: false)
        }
    }
}

#if os(macOS)
private struct WINetworkHiddenWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct WINetworkHiddenWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

private struct WINetworkJSONNode: Identifiable {
    fileprivate enum JSONValue {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    enum DisplayKind {
        case object(count: Int)
        case array(count: Int)
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    let id = UUID()
    let key: String
    let isIndex: Bool
    private let value: JSONValue
    let children: [WINetworkJSONNode]?

    var displayKind: DisplayKind {
        switch value {
        case .object(let dictionary):
            return .object(count: dictionary.count)
        case .array(let array):
            return .array(count: array.count)
        case .string(let value):
            return .string(value)
        case .number(let value):
            return .number(value)
        case .bool(let value):
            return .bool(value)
        case .null:
            return .null
        }
    }

    private init(key: String, value: JSONValue, isIndex: Bool) {
        self.key = key
        self.isIndex = isIndex
        self.value = value
        self.children = WINetworkJSONNode.makeChildren(from: value)
    }

    static func nodes(from text: String) -> [WINetworkJSONNode]? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return nodes(from: object)
    }

    private static func nodes(from object: Any) -> [WINetworkJSONNode] {
        let value = JSONValue.make(from: object)
        return makeChildren(from: value) ?? [WINetworkJSONNode(key: "", value: value, isIndex: false)]
    }

    private static func makeChildren(from value: JSONValue) -> [WINetworkJSONNode]? {
        switch value {
        case .object(let dictionary):
            let keys = Array(dictionary.keys)
            return keys.map { key in
                WINetworkJSONNode(key: key, value: dictionary[key] ?? .null, isIndex: false)
            }
        case .array(let array):
            return array.enumerated().map { index, item in
                WINetworkJSONNode(key: String(index), value: item, isIndex: true)
            }
        default:
            return nil
        }
    }

    private static func truncate(_ value: String, limit: Int = 160) -> String {
        guard value.count > limit else {
            return value
        }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "..."
    }
}

private extension WINetworkJSONNode.JSONValue {
    static func make(from object: Any) -> WINetworkJSONNode.JSONValue {
        if let dictionary = object as? [String: Any] {
            var mapped: [String: WINetworkJSONNode.JSONValue] = [:]
            dictionary.forEach { key, value in
                mapped[key] = make(from: value)
            }
            return .object(mapped)
        }
        if let array = object as? [Any] {
            return .array(array.map { make(from: $0) })
        }
        if let string = object as? String {
            return .string(string)
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(String(describing: number))
        }
        if object is NSNull {
            return .null
        }
        return .string(String(describing: object))
    }
}

private extension View {
    @ViewBuilder
    func fetchButtonStyle() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonSizing(.fitted)
        } else {
            self
                .buttonStyle(.borderedProminent)
        }
    }
}
