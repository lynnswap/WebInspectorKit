import Foundation
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit
import SwiftUI

@MainActor
public final class WINetworkViewController: NSSplitViewController {
    private let inspector: WINetworkModel
    private var hasStartedObservingInspector = false
    private let selectionUpdateCoalescer = UIUpdateCoalescer()
    private var listHostingController: NSHostingController<NetworkMacListTab>?
    private var detailViewController: NetworkMacDetailViewController?

    public init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        inspector.selectEntry(id: nil)

        let listHost = NSHostingController(rootView: NetworkMacListTab(inspector: inspector))
        let detailController = NetworkMacDetailViewController(inspector: inspector)
        listHostingController = listHost
        detailViewController = detailController

        let listItem = NSSplitViewItem(viewController: listHost)
        listItem.minimumThickness = 280
        listItem.preferredThicknessFraction = 0.42
        listItem.canCollapse = false

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 280

        splitViewItems = [listItem, detailItem]

        syncSelection()
        startObservingInspectorIfNeeded()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        syncSelection()
    }

    private func syncSelection() {
        let resolvedSelection = NetworkListSelectionPolicy.resolvedSelection(
            current: inspector.selectedEntry,
            entries: inspector.displayEntries
        )
        if inspector.selectedEntry?.id != resolvedSelection?.id {
            inspector.selectEntry(id: resolvedSelection?.id)
        }
    }

    func canFetchSelectedBodies() -> Bool {
        detailViewController?.canFetchBodies ?? false
    }

    func fetchSelectedBodies(force: Bool) {
        detailViewController?.fetchBodies(force: force)
    }

    private func startObservingInspectorIfNeeded() {
        guard hasStartedObservingInspector == false else {
            return
        }
        hasStartedObservingInspector = true
        inspector.observeTask(
            [
                \.selectedEntry,
                \.searchText,
                \.activeResourceFilters,
                \.effectiveResourceFilters,
                \.sortDescriptors
            ]
        ) { [weak self] in
            self?.scheduleSelectionSync()
        }
        inspector.store.observeTask(
            [
                \.entries
            ]
        ) { [weak self] in
            self?.scheduleSelectionSync()
        }
    }

    private func scheduleSelectionSync() {
        selectionUpdateCoalescer.schedule { [weak self] in
            self?.syncSelection()
        }
    }
}

@MainActor
private final class NetworkMacDetailViewController: NSViewController {
    private let inspector: WINetworkModel
    private var hostingController: NSHostingController<NetworkMacDetailTab>?
    private var fetchTask: Task<Void, Never>?

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        fetchTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let hostingController = NSHostingController(rootView: NetworkMacDetailTab(inspector: inspector))
        self.hostingController = hostingController
        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: view.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        fetchTask?.cancel()
        fetchTask = nil
    }

    private var selectedEntry: NetworkEntry? {
        inspector.selectedEntry
    }

    var canFetchBodies: Bool {
        guard let entry = selectedEntry else {
            return false
        }
        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
    }

    func fetchBodies(force: Bool) {
        guard let entry = selectedEntry else {
            return
        }
        let entryID = entry.id

        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if let requestBody = entry.requestBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: requestBody, force: force)
            }
            if let responseBody = entry.responseBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: responseBody, force: force)
            }
            guard !Task.isCancelled else {
                return
            }
            guard inspector.selectedEntry?.id == entryID else {
                return
            }
            _ = inspector.selectedEntry
        }
    }
}

@MainActor
private struct NetworkMacListTab: View {
    @Bindable var inspector: WINetworkModel

    var body: some View {
        Group {
            if inspector.displayEntries.isEmpty {
                emptyState
            } else {
                Table(inspector.displayEntries, selection: tableSelection) {
                    TableColumn(Text(LocalizedStringResource("network.table.column.request", bundle: .module))) { entry in
                        Text(entry.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.body.weight(.semibold))
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn(Text(LocalizedStringResource("network.table.column.status", bundle: .module))) { entry in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(networkStatusColor(for: entry.statusSeverity))
                                .frame(width: 8, height: 8)
                            Text(entry.statusLabel)
                        }
                        .font(.footnote)
                        .foregroundStyle(networkStatusColor(for: entry.statusSeverity))
                    }
                    .width(min: 92, ideal: 120)

                    TableColumn(Text(LocalizedStringResource("network.table.column.method", bundle: .module))) { entry in
                        Text(entry.method)
                            .font(.footnote.monospaced())
                    }
                    .width(min: 80, ideal: 96)

                    TableColumn(Text(LocalizedStringResource("network.table.column.type", bundle: .module))) { entry in
                        Text(entry.fileTypeLabel)
                            .font(.footnote.monospaced())
                    }
                    .width(min: 88, ideal: 110)

                    TableColumn(Text(LocalizedStringResource("network.table.column.duration", bundle: .module))) { entry in
                        Text(entry.duration.map(entry.durationText(for:)) ?? "-")
                            .font(.footnote)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn(Text(LocalizedStringResource("network.table.column.size", bundle: .module))) { entry in
                        Text(entry.encodedBodyLength.map(entry.sizeText(for:)) ?? "-")
                            .font(.footnote.monospaced())
                    }
                    .width(min: 90, ideal: 110)
                }
                .tableStyle(.inset)
            }
        }
        .padding(8)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tableSelection: Binding<Set<UUID>> {
        Binding(
            get: {
                guard let selected = inspector.selectedEntry?.id else {
                    return []
                }
                return [selected]
            },
            set: { newSelection in
                let nextSelectedEntry = newSelection.first.flatMap { nextSelectedID in
                    inspector.displayEntries.first(where: { $0.id == nextSelectedID })
                }
                let resolved = NetworkListSelectionPolicy.resolvedSelection(
                    current: nextSelectedEntry,
                    entries: inspector.displayEntries
                )
                inspector.selectEntry(id: resolved?.id)
            }
        )
    }
}

@MainActor
private struct NetworkMacDetailTab: View {
    @Bindable var inspector: WINetworkModel

    private var entry: NetworkEntry? {
        inspector.selectedEntry
    }

    private var hasEntries: Bool {
        !inspector.store.entries.isEmpty
    }

    var body: some View {
        if let entry {
            List {
                Section(LocalizedStringResource("network.detail.section.overview", bundle: .module)) {
                    overviewRow(for: entry)
                }

                Section(LocalizedStringResource("network.section.request", bundle: .module)) {
                    headersRows(entry.requestHeaders)
                }

                if let requestBody = entry.requestBody {
                    Section(LocalizedStringResource("network.section.body.request", bundle: .module)) {
                        bodyRow(entry: entry, body: requestBody)
                    }
                }

                Section(LocalizedStringResource("network.section.response", bundle: .module)) {
                    headersRows(entry.responseHeaders)
                }

                if let responseBody = entry.responseBody {
                    Section(LocalizedStringResource("network.section.body.response", bundle: .module)) {
                        bodyRow(entry: entry, body: responseBody)
                    }
                }

                if let error = entry.errorDescription, !error.isEmpty {
                    Section(LocalizedStringResource("network.section.error", bundle: .module)) {
                        errorRow(error)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasEntries {
            ContentUnavailableView {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
            } description: {
                VStack(spacing: 4) {
                    Text(LocalizedStringResource("network.empty.selection.title", bundle: .module))
                    Text(LocalizedStringResource("network.empty.selection.description", bundle: .module))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overviewRow(for entry: NetworkEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(entry.statusLabel)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(networkStatusColor(for: entry.statusSeverity))
                if let duration = entry.duration {
                    Label(entry.durationText(for: duration), systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let encodedBodyLength = entry.encodedBodyLength {
                    Label(entry.sizeText(for: encodedBodyLength), systemImage: "arrow.down.to.line")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.url)
                .font(.footnote.monospaced())
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    @ViewBuilder
    private func headersRows(_ headers: NetworkHeaders) -> some View {
        if headers.isEmpty {
            Text(LocalizedStringResource("network.headers.empty", bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(headers.fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
    }

    private func bodyRow(entry: NetworkEntry, body: NetworkBody) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let typeLabel = networkBodyTypeLabel(entry: entry, body: body) {
                    Label(typeLabel, systemImage: "doc.text")
                }
                if let size = networkBodySize(entry: entry, body: body) {
                    Label(entry.sizeText(for: size), systemImage: "ruler")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let summary = body.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Text(bodyPreviewText(for: body))
                .font(.caption.monospaced())
                .foregroundStyle(bodyPreviewColor(for: body))
                .lineLimit(10)
                .textSelection(.enabled)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }

    private func bodyPreviewText(for body: NetworkBody) -> String {
        if body.kind == .form, !body.formEntries.isEmpty {
            return body.formEntries.prefix(4).map {
                let value: String
                if $0.isFile, let fileName = $0.fileName, !fileName.isEmpty {
                    value = fileName
                } else {
                    value = $0.value
                }
                return "\($0.name): \(value)"
            }.joined(separator: "\n")
        }

        switch body.fetchState {
        case .fetching:
            return wiLocalized("network.body.fetching", default: "Fetching body...")
        case .failed(let error):
            return error.localizedDescriptionText
        default:
            return networkBodyPreviewText(body) ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
        }
    }

    private func bodyPreviewColor(for body: NetworkBody) -> Color {
        switch body.fetchState {
        case .fetching:
            return .secondary
        case .failed:
            return .red
        default:
            return .primary
        }
    }

}

private func networkStatusColor(for severity: NetworkStatusSeverity) -> Color {
    switch severity {
    case .success:
        return .green
    case .notice:
        return .yellow
    case .warning:
        return .orange
    case .error:
        return .red
    case .neutral:
        return .secondary
    }
}

private func networkBodyTypeLabel(entry: NetworkEntry, body: NetworkBody) -> String? {
    let headerValue: String?
    switch body.role {
    case .request:
        headerValue = entry.requestHeaders["content-type"]
    case .response:
        headerValue = entry.responseHeaders["content-type"] ?? entry.mimeType
    }
    if let headerValue, !headerValue.isEmpty {
        let trimmed = headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        return trimmed ?? headerValue
    }
    return body.kind.rawValue.uppercased()
}

private func networkBodySize(entry: NetworkEntry, body: NetworkBody) -> Int? {
    if let size = body.size {
        return size
    }
    switch body.role {
    case .request:
        return entry.requestBodyBytesSent
    case .response:
        return entry.decodedBodyLength ?? entry.encodedBodyLength
    }
}

private func networkBodyPreviewText(_ body: NetworkBody) -> String? {
    if body.kind == .binary {
        return body.displayText
    }
    return decodedBodyText(from: body) ?? body.displayText
}

private func decodedBodyText(from body: NetworkBody) -> String? {
    guard let rawText = body.full ?? body.preview, !rawText.isEmpty else {
        return nil
    }
    guard body.isBase64Encoded else {
        return rawText
    }
    guard let data = Data(base64Encoded: rawText) else {
        return rawText
    }
    return String(data: data, encoding: .utf8) ?? rawText
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Root (AppKit)") {
    WIAppKitPreviewContainer {
        WINetworkViewController(inspector: WINetworkPreviewFixtures.makeInspector(mode: .root))
    }
}

#Preview("Network Root Long Title (AppKit)") {
    WIAppKitPreviewContainer {
        WINetworkViewController(inspector: WINetworkPreviewFixtures.makeInspector(mode: .rootLongTitle))
    }
}
#endif


#endif
