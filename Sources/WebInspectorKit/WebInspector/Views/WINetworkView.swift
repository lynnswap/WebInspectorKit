import SwiftUI

public struct WINetworkView: View {
    private var viewModel: WINetworkViewModel
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.wiNetworkFilters) private var resourceFilters
    @Environment(\.wiNetworkFiltersBinding) private var resourceFiltersBinding
    
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
        .onChange(of: resourceFiltersBinding?.wrappedValue) {
            guard let newValue = resourceFiltersBinding?.wrappedValue else {
                return
            }
            applyResourceFilters(newValue)
        }
        .onChange(of: resourceFilters) {
            guard resourceFiltersBinding == nil, let resourceFilters else {
                return
            }
            applyResourceFilters(resourceFilters)
        }
        .onChange(of: viewModel.activeResourceFilters) {
            guard let binding = resourceFiltersBinding else {
                return
            }
            if binding.wrappedValue != viewModel.effectiveResourceFilters {
                binding.wrappedValue = viewModel.effectiveResourceFilters
            }
        }
        .onAppear {
            if let binding = resourceFiltersBinding {
                applyResourceFilters(binding.wrappedValue)
            } else if let filters = resourceFilters {
                applyResourceFilters(filters)
            }
            viewModel.willAppear()
        }
        .onDisappear {
            viewModel.willDisappear()
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

    private func applyResourceFilters(_ filters: Set<WINetworkResourceFilter>) {
        let normalized = WINetworkResourceFilter.normalizedSelection(filters)
        if viewModel.activeResourceFilters != normalized {
            viewModel.activeResourceFilters = normalized
        }
    }
}

private struct WINetworkTableView: View {
    @Bindable var viewModel: WINetworkViewModel

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
                            .animation(.smooth(duration:0.22),value:entry.statusTint)
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
            .searchable(
                text: $viewModel.searchText,
                prompt: Text(LocalizedStringResource("network.search.placeholder",bundle:.module))
            )
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
    @Bindable var viewModel: WINetworkViewModel
    var body: some View {
        List {
            ForEach(
                viewModel.displayEntries,
            ) { entry in
                NavigationLink(value: entry.id) {
                    WINetworkRow(entry: entry)
                }
            }
        }
        .searchable(
            text: $viewModel.searchText,
            prompt: Text(LocalizedStringResource("network.search.placeholder",bundle:.module))
        )
        .navigationDestination(for: WINetworkEntry.ID.self) { entryID in
            if let entry = viewModel.store.entry(forEntryID: entryID) {
                WINetworkDetailView(entry: entry, viewModel: viewModel)
                    .navigationTitle(entry.displayName)
#if os(iOS)
                    .background(.superClear)
                    .navigationBarTitleDisplayMode(.inline)
#endif
            } else {
                EmptyView()
            }
        }
    }
}
private struct WINetworkRow: View {
    let entry: WINetworkEntry

    var body: some View {
        HStack{
            Circle()
                .fill(entry.statusTint)
                .animation(.smooth(duration:0.22),value:entry.statusTint)
                .frame(width: 8, height: 8)
            Text(entry.displayName)
                .font(.subheadline.weight(.semibold))
                .truncationMode(.middle)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(entry.fileTypeLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
#if DEBUG
@MainActor
func makeWINetworkPreviewModel(
    selectedID: WINetworkEntry.ID? = nil,
    selectEntry: Bool = false
) -> WINetworkViewModel {
    let viewModel = WINetworkViewModel()

    let store = viewModel.store
    if let batch = WINetworkPreviewData.batch {
        batch.events.forEach { store.applyEvent($0) }
    }

    viewModel.selectedEntryID = selectedID ?? (selectEntry ? store.entries.last?.id : nil)
    return viewModel
}

@MainActor
enum WINetworkPreviewData {
    static let events: [[String: Any]] = [
        [
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://x.com/home",
            "method": "GET",
            "headers": [
                "accept": "text/html,application/xhtml+xml",
                "user-agent": "WebInspectorKit/Preview"
            ],
            "initiator": "document",
            "time": [
                "monotonicMs": 1_000.0,
                "wallMs": 1_708_000_000_000.0
            ]
        ],
        [
            "kind": "responseReceived",
            "requestId": 1,
            "status": 200,
            "statusText": "OK",
            "mimeType": "text/html",
            "headers": [
                "content-type": "text/html; charset=utf-8"
            ],
            "time": [
                "monotonicMs": 1_200.0,
                "wallMs": 1_708_000_000_200.0
            ]
        ],
        [
            "kind": "loadingFinished",
            "requestId": 1,
            "encodedBodyLength": 252_779,
            "decodedBodySize": 4_096,
            "body": [
                "kind": "text",
                "encoding": "utf-8",
                "preview": "<!doctype html>",
                "truncated": true,
                "size": 4_096,
                "ref": "res:1"
            ],
            "time": [
                "monotonicMs": 1_400.0,
                "wallMs": 1_708_000_000_400.0
            ]
        ],
        [
            "kind": "requestWillBeSent",
            "requestId": 2,
            "url": "https://api.example.com/report",
            "method": "GET",
            "headers": [
                "accept": "application/json",
                "authorization": "Bearer preview-token"
            ],
            "initiator": "fetch",
            "time": [
                "monotonicMs": 1_900.0,
                "wallMs": 1_708_000_000_900.0
            ]
        ],
        [
            "kind": "responseReceived",
            "requestId": 2,
            "status": 500,
            "statusText": "Internal Server Error",
            "mimeType": "application/json",
            "headers": [
                "content-type": "application/json; charset=utf-8"
            ],
            "time": [
                "monotonicMs": 2_100.0,
                "wallMs": 1_708_000_001_100.0
            ]
        ],
        [
            "kind": "loadingFinished",
            "requestId": 2,
            "body": [
                "kind": "text",
                "encoding": "utf-8",
                "preview": """
{
  "ok": false,
  "error": {
    "code": "timeout",
    "message": "Request timed out"
  },
  "requestId": "preview-2",
  "retryAfterSeconds": 15,
  "flags": [
    "cache-miss",
    "rate-limit"
  ]
}
""",
                "truncated": false
            ],
            "time": [
                "monotonicMs": 2_300.0,
                "wallMs": 1_708_000_001_300.0
            ]
        ]
    ]

    static var batch: NetworkEventBatch? {
        let payload: [String: Any] = [
            "version": 1,
            "sessionId": "preview",
            "seq": 1,
            "events": events
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        return try? JSONDecoder().decode(NetworkEventBatch.self, from: data)
    }
}

#Preview("Network Logs") {
    NavigationStack {
        WINetworkView(viewModel: makeWINetworkPreviewModel(selectEntry: true))
    }
#if os(macOS)
    .frame(height: 420)
#endif
}
#Preview("Filter") {
    NavigationStack {
        List{
            
        }
       
        .sheet(isPresented:.constant(true)){
            NavigationStack{
                WINetworkView(viewModel: makeWINetworkPreviewModel())
                    .toolbar{
                        ToolbarItem{
                            Button{
                                
                            }label:{
                                Image(systemName:"plus")
                            }
                        }
                    }
                  
            }
            .presentationBackgroundInteraction(.enabled)
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
        }
    }
}
#endif
