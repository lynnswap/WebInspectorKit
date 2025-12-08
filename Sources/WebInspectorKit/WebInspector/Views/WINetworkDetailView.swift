import SwiftUI

struct WINetworkDetailView: View {
    let entry: WINetworkEntry
    let viewModel: WINetworkViewModel
    @State private var isFetchingBody = false

    var body: some View {
        List {
            Section {
                summaryRow
            } header: {
                Text("network.detail.section.overview")
            }
            Section {
                WINetworkHeaderSection(headers: entry.requestHeaders)
            } header: {
                Text("network.section.request")
            }
            Section {
                WINetworkHeaderSection(headers: entry.responseHeaders)
            } header: {
                Text("network.section.response")
            }
            if shouldShowResponseBody {
                Section {
                    responseBodyContent
                } header: {
                    Text("network.section.body")
                }
            }
            if let error = entry.errorDescription, !error.isEmpty {
                Section {
                    errorRow(error)
                } header: {
                    Text("network.section.error")
                }
            }
        }
        .listSectionSeparator(.hidden)
        .listStyle(.plain)
#if os(iOS)
        .listRowSpacing(8)
        .listSectionSpacing(12)
#endif
        .contentMargins(.bottom, 24, for: .scrollContent)
    }

    private var summaryRow: some View {
        VStack(alignment: .leading) {
            HStack {
                statusBadge(for: entry)
                if let duration = entry.duration {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                        Text(formatDuration(duration))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let size = entry.encodedBodyLength {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.to.line")
                        Text(formatBytes(size))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Text(entry.url)
                .font(.footnote)
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .networkListRowStyle()
    }

    private func errorRow(_ message: String) -> some View {
        Label {
            Text(message)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .networkListRowStyle()
    }

    @ViewBuilder
    private func statusBadge(for entry: WINetworkEntry) -> some View {
        let tint = entry.statusTint
        Text(entry.statusLabel)
            .font(.caption.weight(.semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        }
        return String(format: "%.2f s", duration)
    }

    private func formatBytes(_ length: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(length))
    }

    private var shouldShowResponseBody: Bool {
        entry.responseBody != nil || entry.responseBodyTruncated || entry.responseBodySize != nil
    }

    @ViewBuilder
    private var responseBodyContent: some View {
        if let body = entry.responseBody {
            Text(body)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(12)
                .networkListRowStyle()
        } else {
            Text("network.body.unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .networkListRowStyle()
        }
        if entry.responseBodyTruncated || (entry.responseBody == nil && entry.responseBodySize != nil) {
            Button {
                fetchFullBody()
            } label: {
                if isFetchingBody {
                    ProgressView()
                } else {
                    Label {
                        Text("network.body.fetch")
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isFetchingBody)
            .networkListRowStyle()
            if entry.responseBodyTruncated {
                Text("network.body.truncated")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .networkListRowStyle()
            }
        }
    }

    private func fetchFullBody() {
        guard !isFetchingBody else { return }
        isFetchingBody = true
        Task {
            await viewModel.fetchResponseBody(for: entry)
            await MainActor.run {
                isFetchingBody = false
            }
        }
    }
}

private struct WINetworkHeaderSection: View {
    let headers: WINetworkHeaders

    var body: some View {
        if headers.isEmpty {
            Text("network.headers.empty")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .networkListRowStyle()
        } else {
            ForEach(headers.fields.indices, id: \.self) { index in
                let header = headers.fields[index]
                headerRow(name: header.name, value: header.value)
            }
        }
    }

    private func headerRow(name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .networkListRowStyle()
    }
}

private extension View {
    func networkListRowStyle() -> some View {
        padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(networkListRowBackground)
            .scenePadding(.horizontal)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(.init())
    }

    @ViewBuilder
    private var networkListRowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.15))
        }
    }
}

extension WINetworkEntry {
    var displayName: String {
        if let url = URL(string: url) {
            let last = url.lastPathComponent
            if !last.isEmpty {
                return last
            }
            if let host {
                return host
            }
        }
        return url
    }

    var fileTypeLabel: String {
        if let mimeType {
            let trimmed = mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
            if let subtype = trimmed.split(separator: "/").last, !subtype.isEmpty {
                return subtype.lowercased()
            }
        }
        if let pathExtension = URL(string: url)?.pathExtension, !pathExtension.isEmpty {
            return pathExtension.lowercased()
        }
        if let requestType, !requestType.isEmpty {
            return requestType
        }
        return "-"
    }

    var host: String? {
        URL(string: url)?.host
    }

    var statusLabel: String {
        if let statusCode, statusCode > 0 {
            return String(statusCode)
        }
        switch phase {
        case .failed:
            return "Failed"
        case .pending:
            return "Pending"
        case .completed:
            return "Finished"
        }
    }

    var statusTint: Color {
        if phase == .failed {
            return .red
        }
        if let statusCode {
            if statusCode >= 500 {
                return .red
            }
            if statusCode >= 400 {
                return .orange
            }
            if statusCode >= 300 {
                return .yellow
            }
            return .green
        }
        if phase == .completed {
            return .green
        }
        return .secondary
    }

    func durationText(for value: TimeInterval) -> String {
        if value < 1 {
            return String(format: "%.0f ms", value * 1000)
        }
        return String(format: "%.2f s", value)
    }

    func sizeText(for length: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(length))
    }
}

#if DEBUG
@MainActor
private func makeWINetworkDetailPreview() -> (entry: WINetworkEntry, viewModel: WINetworkViewModel) {
    let viewModel = makeWINetworkPreviewModel()
    let store = viewModel.store

    guard let entry = viewModel.selectedEntryID.flatMap(store.entry(forEntryID:)) ?? store.entries.last else {
        fatalError("WINetworkDetailView preview requires at least one entry")
    }
    return (entry, viewModel)
}

#Preview("Network Detail") {
    let preview = makeWINetworkDetailPreview()
    return NavigationStack {
        WINetworkDetailView(entry: preview.entry, viewModel: preview.viewModel)
    }
#if os(macOS)
    .frame(width: 540, height: 480)
#endif
}
#endif
