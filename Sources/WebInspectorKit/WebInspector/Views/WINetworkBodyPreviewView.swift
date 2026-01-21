import Foundation
import SwiftUI

struct WINetworkBodyPreviewView: View {
    private enum PreviewMode: String, CaseIterable, Identifiable {
        case text
        case json

        var id: String { rawValue }

        var localized: LocalizedStringResource {
            switch self {
            case .text:
                return LocalizedStringResource("network.body.preview.mode.text", bundle: .module)
            case .json:
                return LocalizedStringResource("network.body.preview.mode.json", bundle: .module)
            }
        }

        var icon: String {
            switch self {
            case .text:
                return "text.document"
            case .json:
                return "o.square.fill"
            }
        }
    }

    let entry: WINetworkEntry
    let viewModel: WINetworkViewModel
    let bodyState: WINetworkBody

    @State private var selectedMode: PreviewMode = .text

    var body: some View {
        let previewData = bodyState.previewData
        let availableModes = previewModes(from: previewData)
        Group {
            switch selectedMode {
            case .text:
                WINetworkTextPreviewView(text: previewData.text, summary: bodyState.summary)
            case .json:
                WINetworkJSONPreviewView(nodes: previewData.jsonNodes ?? [])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack {
                    Text(previewTitle)
                    if case let .failed(error) = bodyState.fetchState {
                        Text(error.localizedResource)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if availableModes.count > 1 {
                    Picker("network.body.preview", selection: $selectedMode) {
                        ForEach(availableModes) { mode in
                            Label(mode.localized, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }
                    .fixedSize()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                if bodyState.canFetchBody {
                    Button {
                        if bodyState.fetchState == .fetching {
                            return
                        }
                        Task {
                            await viewModel.fetchBodyIfNeeded(for: entry, body: bodyState, force: true)
                        }
                    } label: {
                        Label{
                            Text("network.body.fetch")
                        }icon:{
                            if bodyState.fetchState == .fetching {
                                ProgressView()
                            }else{
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(previewTitle)
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear {
            selectedMode = preferredMode(from: availableModes)
        }
        .onChange(of: availableModes) { _, newModes in
            if newModes.contains(selectedMode) {
                return
            }
            selectedMode = preferredMode(from: newModes)
        }
        .task {
            await viewModel.fetchBodyIfNeeded(for: entry, body: bodyState)
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

    private func previewModes(from previewData: WINetworkBodyPreviewData) -> [PreviewMode] {
        var modes: [PreviewMode] = [.text]
        if previewData.jsonNodes != nil {
            modes.append(.json)
        }
        return modes
    }

    private func preferredMode(from modes: [PreviewMode]) -> PreviewMode {
        if modes.contains(.json) {
            return .json
        }
        return .text
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
                    Text(":" as String)
                        .foregroundStyle(.secondary)
                }
                Text(valueText)
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
