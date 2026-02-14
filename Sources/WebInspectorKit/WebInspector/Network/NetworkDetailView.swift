import SwiftUI
import WebInspectorKitCore

extension WebInspector {
    struct NetworkDetailView: View {
        let entry: NetworkEntry
        let inspector: NetworkInspector

        var body: some View {
            List {
                Section {
                    summaryRow
                } header: {
                    Text(LocalizedStringResource("network.detail.section.overview", bundle: .module))
                }
                Section {
                    NetworkHeaderSection(headers: entry.requestHeaders)
                } header: {
                    Text(LocalizedStringResource("network.section.request", bundle: .module))
                }

                if let requestBody = entry.requestBody {
                    Section {
                        NetworkBodySectionView(entry: entry, inspector: inspector, bodyState: requestBody)
                    } header: {
                        Text(LocalizedStringResource("network.section.body.request", bundle: .module))
                    }
                }

                Section {
                    NetworkHeaderSection(headers: entry.responseHeaders)
                } header: {
                    Text(LocalizedStringResource("network.section.response", bundle: .module))
                }

                if let responseBody = entry.responseBody {
                    Section {
                        NetworkBodySectionView(entry: entry, inspector: inspector, bodyState: responseBody)
                    } header: {
                        Text(LocalizedStringResource("network.section.body.response", bundle: .module))
                    }
                }

                if let error = entry.errorDescription, !error.isEmpty {
                    Section {
                        errorRow(error)
                    } header: {
                        Text(LocalizedStringResource("network.section.error", bundle: .module))
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
        private func statusBadge(for entry: NetworkEntry) -> some View {
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
}

private struct NetworkHeaderSection: View {
    let headers: NetworkHeaders

    var body: some View {
        if headers.isEmpty {
            Text(LocalizedStringResource("network.headers.empty", bundle: .module))
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

