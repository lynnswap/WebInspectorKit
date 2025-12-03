import SwiftUI

public struct WINetworkView: View {
    @Environment(WebInspectorModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var store = model.networkAgent.store

        VStack(spacing: 0) {
            controlBar(
                isRecording: store.isRecording,
                requestCount: store.entries.count,
                isClearDisabled: store.entries.isEmpty
            )
            Divider()
            if store.entries.isEmpty {
                emptyState
            } else {
                List(selection: $store.selectedEntryID) {
                    ForEach(store.entries) { entry in
                        WINetworkRow(entry: entry)
                            .contentShape(Rectangle())
                            .tag(entry.id)
                            .onTapGesture {
                                store.selectedEntryID = entry.id
                            }
                    }
                }
                .listStyle(.plain)
            }
            if let selected = store.entry(for: store.selectedEntryID) {
                Divider()
                detailView(selected)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: store.entries.count)
        .animation(.easeInOut(duration: 0.16), value: store.selectedEntryID)
    }

    private func controlBar(isRecording: Bool, requestCount: Int, isClearDisabled: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                model.setNetworkRecording(!isRecording)
            } label: {
                Label {
                    Text(isRecording ? "network.controls.pause" : "network.controls.record", bundle: .module)
                } icon: {
                    Image(systemName: isRecording ? "pause.circle" : "record.circle")
                }
            }
            .buttonStyle(.bordered)

            Button {
                model.clearNetworkLogs()
            } label: {
                Label {
                    Text("network.controls.clear", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isClearDisabled)

            Spacer()

            Text(requestCount, format: .number)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Image(systemName: "waveform.path")
                .foregroundStyle(.secondary)
        } description: {
            VStack(spacing: 4) {
                Text("network.empty.title", bundle: .module)
                Text("network.empty.description", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func detailView(_ entry: WINetworkEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    statusBadge(for: entry)
                    if let duration = entry.duration {
                        Label {
                            Text(formatDuration(duration))
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let size = entry.encodedBodyLength {
                        Label {
                            Text(formatBytes(size))
                        } icon: {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Text(entry.url)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .lineLimit(4)

                headerGroup(
                    title: "network.section.request",
                    headers: entry.requestHeaders
                )
                headerGroup(
                    title: "network.section.response",
                    headers: entry.responseHeaders
                )

                if let error = entry.errorDescription, !error.isEmpty {
                    Label {
                        Text(error)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
    }

    private func headerGroup(title: LocalizedStringKey, headers: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title, bundle: .module)
                .font(.subheadline.weight(.semibold))
            if headers.isEmpty {
                Text("network.headers.empty", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(headers.keys.sorted(), id: \.self) { key in
                        if let value = headers[key] {
                            headerRow(name: key, value: value)
                        }
                    }
                }
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
    }

    private func statusBadge(for entry: WINetworkEntry) -> some View {
        let tint = entry.statusTint
        return Text(entry.statusLabel)
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

private struct WINetworkRow: View {
    let entry: WINetworkEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.method)
                .font(.caption.weight(.semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let host = entry.host {
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.statusTint)
                HStack(spacing: 8) {
                    if let duration = entry.duration {
                        Text(entry.durationText(for: duration))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let size = entry.encodedBodyLength {
                        Text(entry.sizeText(for: size))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private extension WINetworkEntry {
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
            return String(localized: "network.status.failed", bundle: .module)
        case .pending, .completed:
            return String(localized: "network.status.pending", bundle: .module)
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
