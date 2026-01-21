import SwiftUI

struct WINetworkDetailView: View {
    let entry: WINetworkEntry
    let viewModel: WINetworkViewModel

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
            
            if let requestBody = entry.requestBody {
                Section {
                    WINetworkBodySectionView(
                        entry: entry,
                        viewModel: viewModel,
                        bodyState: requestBody
                    )
                } header: {
                    Text("network.section.body.request")
                }
            }
            
            Section {
                WINetworkHeaderSection(headers: entry.responseHeaders)
            } header: {
                Text("network.section.response")
            }
            
            if let bodyState = entry.responseBody {
                Section {
                    WINetworkBodySectionView(
                        entry: entry,
                        viewModel: viewModel,
                        bodyState: bodyState
                    )
                } header: {
                    Text("network.section.body.response")
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

extension View {
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
    var networkListRowBackground: some View {
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

@MainActor
private func makeWINetworkDetailNeedsFetchPreview() -> (entry: WINetworkEntry, viewModel: WINetworkViewModel) {
    let viewModel = makeWINetworkPreviewModel()
    let store = viewModel.store

    let entry = store.entries.first { entry in
        if let requestBody = entry.requestBody,
           requestBody.fetchState != .full,
           let reference = requestBody.reference,
           !reference.isEmpty {
            return true
        }
        if let responseBody = entry.responseBody,
           responseBody.fetchState != .full,
           let reference = responseBody.reference,
           !reference.isEmpty {
            return true
        }
        return false
    }

    guard let resolvedEntry = entry ?? store.entries.last else {
        fatalError("WINetworkDetailView preview requires at least one entry")
    }
    return (resolvedEntry, viewModel)
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

#Preview("Network Detail (Needs Fetch)") {
    let preview = makeWINetworkDetailNeedsFetchPreview()
    return NavigationStack {
        WINetworkDetailView(entry: preview.entry, viewModel: preview.viewModel)
    }
#if os(macOS)
    .frame(width: 540, height: 480)
#endif
}
#endif
