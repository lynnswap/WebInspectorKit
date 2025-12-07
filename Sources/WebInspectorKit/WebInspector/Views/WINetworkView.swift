import SwiftUI

public struct WINetworkView: View {
    private var viewModel: WINetworkViewModel
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    public init(viewModel: WINetworkViewModel) {
        self.viewModel = viewModel
    }
    private var store: WINetworkStore {
        viewModel.store
    }

    public var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                if horizontalSizeClass == .compact{
                    WINetworkListView(viewModel: viewModel)
                }else{
                    WINetworkTableView(viewModel: viewModel)
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: store.entries.count)
        .sheet(isPresented: viewModel.isShowingDetail) {
            NavigationStack {
                if let isSelectedEntryID = viewModel.selectedEntryID,
                   let entry = store.entry(for:isSelectedEntryID) {
                    WINetworkDetailView(entry: entry)
                        .scrollContentBackground(.hidden)
                }
            }
#if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled)
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.hidden)
#endif
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Section {
                    Button(role: .destructive) {
                        viewModel.clearNetworkLogs()
                    } label: {
                        Label {
                            Text("network.controls.clear", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(store.entries.isEmpty)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Image(systemName: "waveform.path.ecg.rectangle")
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
}

private struct WINetworkTableView: View {
    var viewModel: WINetworkViewModel

    var body: some View {
        Table(viewModel.store.entries.reversed(), selection: viewModel.tableSelection) {
            TableColumn(Text("network.table.column.request", bundle: .module)) { entry in
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .width(min: 220)
            TableColumn(Text("network.table.column.status", bundle: .module)) { entry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(entry.statusTint)
                        .frame(width: 8, height: 8)
                    Text(entry.statusLabel)
                }
                .font(.footnote)
                .foregroundStyle(entry.statusTint)
            }
            .width(min: 80, ideal: 100)
            TableColumn(Text("network.table.column.method", bundle: .module)) { entry in
                Text(entry.method)
                    .font(.footnote.monospaced())
            }
            .width(min: 72, ideal: 90)
            TableColumn(Text("network.table.column.type", bundle: .module)) { entry in
                Text(entry.fileTypeLabel)
                    .font(.footnote.monospaced())
            }
            .width(min: 80, ideal: 120)
            TableColumn(Text("network.table.column.duration", bundle: .module)) { entry in
                Text(entry.duration.map(entry.durationText(for:)) ?? "-")
                    .font(.footnote)
            }
            .width(min: 90, ideal: 110)
            TableColumn(Text("network.table.column.size", bundle: .module)) { entry in
                Group {
                    if let length = entry.encodedBodyLength {
                        Text(entry.sizeText(for: length))
                    } else {
                        Text("-")
                    }
                }
                .font(.footnote.monospaced())
            }
            .width(min: 90, ideal: 110)
        }
    }
}
private struct WINetworkListView: View {
    @Bindable var viewModel:WINetworkViewModel
    var body:some View{
        List(selection:$viewModel.selectedEntryID) {
            ForEach(viewModel.store.entries.reversed()) { entry in
                WINetworkRow(entry: entry)
                    .contentShape(.rect)
                    .onTapGesture {
                        viewModel.selectedEntryID = entry.id
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }
}
private struct WINetworkRow: View {
    let entry: WINetworkEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack{
                Circle()
                    .fill(entry.statusTint)
                    .frame(width: 8, height: 8)
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(entry.method)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


private struct WINetworkDetailView: View {
    let entry: WINetworkEntry

    var body: some View {
        List {
            Section {
                summaryRow
            } header: {
                Text("network.detail.section.overview", bundle: .module)
            }
            Section {
                WINetworkHeaderSection(headers: entry.requestHeaders)
            }header:{
                Text("network.section.request", bundle: .module)
            }
            Section{
                WINetworkHeaderSection(headers: entry.responseHeaders)
            }header:{
                Text("network.section.response", bundle: .module)
            }
            if let error = entry.errorDescription, !error.isEmpty {
                Section {
                    errorRow(error)
                } header: {
                    Text("network.section.error", bundle: .module)
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
                    HStack(spacing:8){
                        Image(systemName: "clock")
                        Text(formatDuration(duration))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let size = entry.encodedBodyLength {
                    HStack(spacing:8){
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
            Text("network.headers.empty", bundle: .module)
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
            return String(localized: "network.status.failed", bundle: .module)
        case .pending:
            return String(localized: "network.status.pending", bundle: .module)
        case .completed:
            return String(localized: "network.status.completed", bundle: .module)
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
private func makeWINetworkPreviewModel(selectedID: String? = nil) -> WINetworkViewModel {
    let viewModel = WINetworkViewModel()
    let store = viewModel.store
    WINetworkPreviewData.events
        .compactMap(WINetworkEventPayload.init(dictionary:))
        .forEach { store.applyEvent($0) }
    if let selectedID, store.entry(for: selectedID) != nil {
        viewModel.selectedEntryID = selectedID
    } else if let newestID = store.entries.last?.id {
        viewModel.selectedEntryID = newestID
    }
    return viewModel
}

@MainActor
private enum WINetworkPreviewData {
    static let primaryID = "net_home"
    static let events: [[String: Any]] = [
        [
            "type": "start",
            "id": "net_home",
            "url": "https://x.com/home",
            "method": "GET",
            "requestHeaders": [
                "accept": "text/html,application/xhtml+xml",
                "user-agent": "WebInspectorKit/Preview"
            ],
            "startTime": 1_000.0,
            "wallTime": 1_708_000_000_000.0,
            "requestType": "document"
        ],
        [
            "type": "response",
            "id": "net_home",
            "status": 200,
            "statusText": "OK",
            "mimeType": "text/html",
            "responseHeaders": [
                "content-type": "text/html; charset=utf-8",
                "cache-control": "no-cache"
            ],
            "endTime": 1_140.0,
            "wallTime": 1_708_000_000_140.0,
            "requestType": "document"
        ],
        [
            "type": "finish",
            "id": "net_home",
            "endTime": 1_170.0,
            "wallTime": 1_708_000_000_170.0,
            "encodedBodyLength": 252_779,
            "requestType": "document"
        ],
        [
            "type": "start",
            "id": "net_avatar_1",
            "url": "https://cdn.example.com/images/9AxiduZ7_x96.png",
            "method": "GET",
            "requestHeaders": [
                "accept": "image/avif,image/webp,image/png,*/*"
            ],
            "startTime": 1_300.0,
            "wallTime": 1_708_000_000_300.0,
            "requestType": "image"
        ],
        [
            "type": "response",
            "id": "net_avatar_1",
            "status": 200,
            "statusText": "OK",
            "mimeType": "image/png",
            "responseHeaders": [
                "content-type": "image/png",
                "cache-control": "public, max-age=31536000"
            ],
            "endTime": 1_326.0,
            "wallTime": 1_708_000_000_326.0,
            "requestType": "image"
        ],
        [
            "type": "finish",
            "id": "net_avatar_1",
            "endTime": 1_326.0,
            "wallTime": 1_708_000_000_326.0,
            "encodedBodyLength": 1_657,
            "requestType": "image"
        ],
        [
            "type": "start",
            "id": "net_avatar_2",
            "url": "https://cdn.example.com/images/j7ETageC_x96.jpg",
            "method": "GET",
            "requestHeaders": [
                "accept": "image/avif,image/webp,image/jpeg,*/*"
            ],
            "startTime": 1_360.0,
            "wallTime": 1_708_000_000_360.0,
            "requestType": "image"
        ],
        [
            "type": "response",
            "id": "net_avatar_2",
            "status": 200,
            "statusText": "OK",
            "mimeType": "image/jpeg",
            "responseHeaders": [
                "content-type": "image/jpeg"
            ],
            "endTime": 1_535.0,
            "wallTime": 1_708_000_000_535.0,
            "requestType": "image"
        ],
        [
            "type": "finish",
            "id": "net_avatar_2",
            "endTime": 1_535.0,
            "wallTime": 1_708_000_000_535.0,
            "encodedBodyLength": 3_550,
            "requestType": "image"
        ],
        [
            "type": "start",
            "id": "net_avatar_3",
            "url": "https://cdn.example.com/images/J0iMVfNY_normal.png",
            "method": "GET",
            "requestHeaders": [
                "accept": "image/avif,image/webp,image/png,*/*"
            ],
            "startTime": 1_600.0,
            "wallTime": 1_708_000_000_600.0,
            "requestType": "image"
        ],
        [
            "type": "response",
            "id": "net_avatar_3",
            "status": 200,
            "statusText": "OK",
            "mimeType": "image/png",
            "responseHeaders": [
                "content-type": "image/png"
            ],
            "endTime": 1_622.0,
            "wallTime": 1_708_000_000_622.0,
            "requestType": "image"
        ],
        [
            "type": "finish",
            "id": "net_avatar_3",
            "endTime": 1_622.0,
            "wallTime": 1_708_000_000_622.0,
            "encodedBodyLength": 1_959,
            "requestType": "image"
        ],
        [
            "type": "start",
            "id": "net_flow",
            "url": "https://api.example.com/user_flow.json",
            "method": "POST",
            "requestHeaders": [
                "content-type": "application/json",
                "accept": "application/json"
            ],
            "startTime": 1_750.0,
            "wallTime": 1_708_000_000_750.0,
            "requestType": "fetch"
        ],
        [
            "type": "response",
            "id": "net_flow",
            "status": 200,
            "statusText": "OK",
            "mimeType": "application/json",
            "responseHeaders": [
                "content-type": "application/json; charset=utf-8"
            ],
            "endTime": 1_978.0,
            "wallTime": 1_708_000_000_978.0,
            "requestType": "fetch"
        ],
        [
            "type": "finish",
            "id": "net_flow",
            "endTime": 1_978.0,
            "wallTime": 1_708_000_000_978.0,
            "encodedBodyLength": 0,
            "requestType": "fetch"
        ],
        [
            "type": "start",
            "id": "net_update",
            "url": "https://api.example.com/update_subscriptions",
            "method": "POST",
            "requestHeaders": [
                "content-type": "application/json",
                "accept": "application/json"
            ],
            "startTime": 1_900.0,
            "wallTime": 1_708_000_000_900.0,
            "requestType": "fetch"
        ],
        [
            "type": "response",
            "id": "net_update",
            "status": 200,
            "statusText": "OK",
            "mimeType": "application/json",
            "responseHeaders": [
                "content-type": "application/json; charset=utf-8"
            ],
            "endTime": 2_042.0,
            "wallTime": 1_708_000_001_042.0,
            "requestType": "fetch"
        ],
        [
            "type": "finish",
            "id": "net_update",
            "endTime": 2_042.0,
            "wallTime": 1_708_000_001_042.0,
            "encodedBodyLength": 35,
            "requestType": "fetch"
        ],
        [
            "type": "start",
            "id": "net_upload_fail",
            "url": "https://upload.example.com/media",
            "method": "POST",
            "requestHeaders": [
                "content-type": "application/json",
                "accept": "application/json"
            ],
            "startTime": 2_120.0,
            "wallTime": 1_708_000_001_120.0,
            "requestType": "fetch"
        ],
        [
            "type": "response",
            "id": "net_upload_fail",
            "status": 500,
            "statusText": "Internal Server Error",
            "mimeType": "application/json",
            "responseHeaders": [
                "content-type": "application/json; charset=utf-8",
                "retry-after": "30"
            ],
            "endTime": 2_210.0,
            "wallTime": 1_708_000_001_210.0,
            "requestType": "fetch"
        ],
        [
            "type": "fail",
            "id": "net_upload_fail",
            "error": "Request timed out",
            "endTime": 2_400.0,
            "wallTime": 1_708_000_001_400.0,
            "requestType": "fetch"
        ],
        [
            "type": "start",
            "id": "net_stream",
            "url": "https://stream.example.com/live",
            "method": "GET",
            "requestHeaders": [
                "accept": "text/event-stream",
                "cache-control": "no-cache"
            ],
            "startTime": 2_320.0,
            "wallTime": 1_708_000_001_320.0,
            "requestType": "event-stream"
        ]
    ]
}

#Preview("Network Logs") {
    NavigationStack {
        WINetworkView(viewModel: makeWINetworkPreviewModel(selectedID: WINetworkPreviewData.primaryID))
    }
#if os(macOS)
    .frame(height: 420)
#endif
}
#endif
