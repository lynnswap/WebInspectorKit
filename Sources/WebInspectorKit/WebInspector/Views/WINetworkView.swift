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
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Section {
                    Button(role: .destructive) {
                        viewModel.clearNetworkLogs()
                    } label: {
                        Label {
                            Text("network.controls.clear")
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
                Text("network.empty.title")
                Text("network.empty.description")
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
        GeometryReader{ proxy in
            Table(
                viewModel.displayEntries,
                selection: viewModel.tableSelection
            ) {
                TableColumn(Text("network.table.column.request")) { entry in
                    Text(entry.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .width(min: 220)
                TableColumn(Text("network.table.column.status")) { entry in
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
                TableColumn(Text("network.table.column.method")) { entry in
                    Text(entry.method)
                        .font(.footnote.monospaced())
                }
                .width(min: 72, ideal: 90)
                TableColumn(Text("network.table.column.type")) { entry in
                    Text(entry.fileTypeLabel)
                        .font(.footnote.monospaced())
                }
                .width(min: 80, ideal: 120)
                TableColumn(Text("network.table.column.duration")) { entry in
                    Text(entry.duration.map(entry.durationText(for:)) ?? "-")
                        .font(.footnote)
                }
                .width(min: 90, ideal: 110)
                TableColumn(Text("network.table.column.size")) { entry in
                    Group {
                        if let length = entry.encodedBodyLength {
                            Text(entry.sizeText(for: length))
                        } else {
                            Text("-" as String)
                        }
                    }
                    .font(.footnote.monospaced())
                }
                .width(min: 90, ideal: 110)
            }
            .inspector(isPresented: viewModel.isShowingDetail) {
                NavigationStack {
                    if let isSelectedEntryID = viewModel.selectedEntryID,
                       let entry = viewModel.store.entry(forEntryID: isSelectedEntryID) {
                        WINetworkDetailView(entry: entry, viewModel: viewModel)
                            .toolbar{
                                ToolbarItem(placement:.primaryAction){
                                    Button(role:.closeRole){
                                        viewModel.selectedEntryID = nil
                                    }label:{
                                        Image(systemName:"sidebar.trailing")
                                    }
                                }
                            }
                    }
                }
                .inspectorColumnWidth(ideal: proxy.size.width * 0.5,max:proxy.size.width * 0.8)
            }
        }
    }
}
private struct WINetworkListView: View {
    @Bindable var viewModel:WINetworkViewModel
    var body:some View{
        List(selection: viewModel.tableSelection) {
            ForEach(
                viewModel.displayEntries,
            ) { entry in
                WINetworkRow(entry: entry)
                    .contentShape(.rect)
                    .onTapGesture {
                        viewModel.selectedEntryID = entry.id
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .sheet(isPresented: viewModel.isShowingDetail) {
            NavigationStack {
                if let isSelectedEntryID = viewModel.selectedEntryID,
                   let entry = viewModel.store.entry(forEntryID:isSelectedEntryID) {
                    WINetworkDetailView(entry: entry, viewModel: viewModel)
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
#if DEBUG
@MainActor
func makeWINetworkPreviewModel(selectedID: WINetworkEntry.ID? = nil) -> WINetworkViewModel {
    let viewModel = WINetworkViewModel()
    let store = viewModel.store
    WINetworkPreviewData.events
        .compactMap(HTTPNetworkEvent.init(dictionary:))
        .forEach { store.applyEvent($0) }
    
    viewModel.selectedEntryID = selectedID ?? store.entries.last?.id
    return viewModel
}

@MainActor
enum WINetworkPreviewData {
    static let events: [[String: Any]] = [
        [
            "type": "start",
            "requestId": 1,
            "session": "preview",
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
            "requestId": 1,
            "session": "preview",
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
            "requestId": 1,
            "session": "preview",
            "endTime": 1_170.0,
            "wallTime": 1_708_000_000_170.0,
            "encodedBodyLength": 252_779,
            "requestType": "document"
        ],
        [
            "type": "start",
            "requestId": 2,
            "session": "preview",
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
            "requestId": 2,
            "session": "preview",
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
            "requestId": 2,
            "session": "preview",
            "endTime": 1_326.0,
            "wallTime": 1_708_000_000_326.0,
            "encodedBodyLength": 1_657,
            "requestType": "image"
        ],
        [
            "type": "start",
            "requestId": 3,
            "session": "preview",
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
            "requestId": 3,
            "session": "preview",
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
            "requestId": 3,
            "session": "preview",
            "endTime": 1_535.0,
            "wallTime": 1_708_000_000_535.0,
            "encodedBodyLength": 3_550,
            "requestType": "image"
        ],
        [
            "type": "start",
            "requestId": 4,
            "session": "preview",
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
            "requestId": 4,
            "session": "preview",
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
            "requestId": 4,
            "session": "preview",
            "endTime": 1_622.0,
            "wallTime": 1_708_000_000_622.0,
            "encodedBodyLength": 1_959,
            "requestType": "image"
        ],
        [
            "type": "start",
            "requestId": 5,
            "session": "preview",
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
            "requestId": 5,
            "session": "preview",
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
            "requestId": 5,
            "session": "preview",
            "endTime": 1_978.0,
            "wallTime": 1_708_000_000_978.0,
            "encodedBodyLength": 0,
            "requestType": "fetch"
        ],
        [
            "type": "start",
            "requestId": 6,
            "session": "preview",
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
            "requestId": 6,
            "session": "preview",
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
            "requestId": 6,
            "session": "preview",
            "endTime": 2_042.0,
            "wallTime": 1_708_000_001_042.0,
            "encodedBodyLength": 35,
            "requestType": "fetch"
        ],
        [
            "type": "start",
            "requestId": 7,
            "session": "preview",
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
            "requestId": 7,
            "session": "preview",
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
            "requestId": 7,
            "session": "preview",
            "error": "Request timed out",
            "endTime": 2_400.0,
            "wallTime": 1_708_000_001_400.0,
            "requestType": "fetch"
        ],
        [
            "type": "start",
            "requestId": 8,
            "session": "preview",
            "url": "https://stream.example.com/live",
            "method": "GET",
            "requestHeaders": [
                "accept": "text/event-stream",
                "cache-control": "no-cache"
            ],
            "startTime": 2_320.0,
            "wallTime": 1_708_000_001_320.0,
            "requestType": "event-stream"
        ],
        [
            "type": "start",
            "requestId": 9,
            "session": "preview",
            "url": "https://api.example.com/report",
            "method": "GET",
            "requestHeaders": [
                "accept": "application/json",
                "authorization": "Bearer preview-token"
            ],
            "startTime": 2_460.0,
            "wallTime": 1_708_000_001_460.0,
            "requestType": "fetch"
        ],
        [
            "type": "response",
            "requestId": 9,
            "session": "preview",
            "status": 206,
            "statusText": "Partial Content",
            "mimeType": "application/json",
            "responseHeaders": [
                "content-type": "application/json; charset=utf-8",
                "content-range": "bytes 0-1023/20480"
            ],
            "endTime": 2_640.0,
            "wallTime": 1_708_000_001_640.0,
            "requestType": "fetch"
        ],
        [
            "type": "finish",
            "requestId": 9,
            "session": "preview",
            "status": 206,
            "statusText": "Partial Content",
            "mimeType": "application/json",
            "responseBody": """
            {
              "data": ["alpha", "beta", "gamma"],
              "next_page": "/report?page=2"
            }
            """,
            "responseBodyTruncated": true,
            "responseBodySize": 20_480,
            "encodedBodyLength": 1_024,
            "endTime": 2_740.0,
            "wallTime": 1_708_000_001_740.0,
            "requestType": "fetch"
        ]
    ]
}

#Preview("Network Logs") {
    NavigationStack {
        WINetworkView(viewModel: makeWINetworkPreviewModel())
    }
#if os(macOS)
    .frame(height: 420)
#endif
}
#endif
