import Observation
import SwiftUI
import WebInspectorKitCore

extension WebInspector {
    public struct NetworkView: View {
        @Bindable private var inspector: NetworkInspector

        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        public init(inspector: NetworkInspector) {
            self.inspector = inspector
        }

        public var body: some View {
            Group {
                if inspector.store.entries.isEmpty {
                    emptyState
                } else if horizontalSizeClass == .compact {
                    NetworkListView(inspector: inspector)
                } else {
                    NetworkTableView(inspector: inspector)
                }
            }
            .networkInspectorToolbar(inspector)
        }

        private var emptyState: some View {
            ContentUnavailableView {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .foregroundStyle(.secondary)
            } description: {
                VStack(spacing: 4) {
                    Text(LocalizedStringResource("network.empty.title", bundle: .module))
                    Text(LocalizedStringResource("network.empty.description", bundle: .module))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

private struct NetworkTableView: View {
    @Bindable var inspector: WebInspector.NetworkInspector

    var body: some View {
        GeometryReader { proxy in
            Table(inspector.displayEntries, selection: inspector.tableSelection) {
                TableColumn(Text(LocalizedStringResource("network.table.column.request", bundle: .module))) { entry in
                    Text(entry.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .width(min: 220)
                TableColumn(Text(LocalizedStringResource("network.table.column.status", bundle: .module))) { entry in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.statusTint)
                            .animation(.smooth(duration: 0.22), value: entry.statusTint)
                            .frame(width: 8, height: 8)
                        Text(entry.statusLabel)
                    }
                    .font(.footnote)
                    .foregroundStyle(entry.statusTint)
                }
                .width(min: 80, ideal: 100)
                TableColumn(Text(LocalizedStringResource("network.table.column.method", bundle: .module))) { entry in
                    Text(entry.method)
                        .font(.footnote.monospaced())
                }
                .width(min: 72, ideal: 90)
                TableColumn(Text(LocalizedStringResource("network.table.column.type", bundle: .module))) { entry in
                    Text(entry.fileTypeLabel)
                        .font(.footnote.monospaced())
                }
                .width(min: 80, ideal: 120)
                TableColumn(Text(LocalizedStringResource("network.table.column.duration", bundle: .module))) { entry in
                    Text(entry.duration.map(entry.durationText(for:)) ?? "-")
                        .font(.footnote)
                }
                .width(min: 90, ideal: 110)
                TableColumn(Text(LocalizedStringResource("network.table.column.size", bundle: .module))) { entry in
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
                text: $inspector.searchText,
                prompt: Text(LocalizedStringResource("network.search.placeholder", bundle: .module))
            )
            .inspector(isPresented: inspector.isShowingDetail) {
                NavigationStack {
                    if let selectedEntryID = inspector.selectedEntryID,
                       let entry = inspector.store.entry(forEntryID: selectedEntryID) {
                        WebInspector.NetworkDetailView(entry: entry, inspector: inspector)
                            .toolbar {
                                ToolbarItem(placement: .primaryAction) {
                                    Button(role: .closeRole) {
                                        inspector.selectedEntryID = nil
                                    } label: {
                                        Image(systemName: "sidebar.trailing")
                                    }
                                }
                            }
                    }
                }
                .inspectorColumnWidth(ideal: proxy.size.width * 0.5, max: proxy.size.width * 0.8)
            }
        }
    }
}

private struct NetworkListView: View {
    @Bindable var inspector: WebInspector.NetworkInspector

    var body: some View {
        List {
            ForEach(inspector.displayEntries) { entry in
                NavigationLink(value: entry.id) {
                    NetworkRow(entry: entry)
                }
            }
        }
        .searchable(
            text: $inspector.searchText,
            prompt: Text(LocalizedStringResource("network.search.placeholder", bundle: .module))
        )
        .navigationDestination(for: UUID.self) { entryID in
            if let entry = inspector.store.entry(forEntryID: entryID) {
                WebInspector.NetworkDetailView(entry: entry, inspector: inspector)
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

private struct NetworkRow: View {
    let entry: NetworkEntry

    var body: some View {
        HStack {
            Circle()
                .fill(entry.statusTint)
                .animation(.smooth(duration: 0.22), value: entry.statusTint)
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

