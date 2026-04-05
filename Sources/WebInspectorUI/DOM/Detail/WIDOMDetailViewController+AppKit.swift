import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit
import SwiftUI

@MainActor
public final class WIDOMDetailViewController: NSViewController {
    private let inspector: WIDOMInspector
    private var hostingController: NSHostingController<ElementDetailsMacRootView>?

    public init(inspector: WIDOMInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        view = NSView(frame: .zero)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let hostingController = NSHostingController(rootView: ElementDetailsMacRootView(inspector: inspector))
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
}

@MainActor
private struct ElementDetailsMacRootView: View {
    let inspector: WIDOMInspector

    @State private var draftSession: WIDOMAttributeDraftSession?
    @State private var isDraftSaveInFlight = false
    @State private var pendingDraftSelectionClearTask: Task<Void, Never>?

    private var selectedNode: DOMNodeModel? {
        inspector.document.selectedNode
    }

    private var hasSelection: Bool {
        selectedNode != nil
    }

    var body: some View {
        Group {
            if let selectedNode {
                List {
                    if let errorMessage = inspector.document.errorMessage, !errorMessage.isEmpty {
                        Section {
                            infoRow(message: errorMessage, color: .orange)
                        }
                    }

                    Section(LocalizedStringResource("dom.element.section.element", bundle: .module)) {
                        previewRow(selectedNode: selectedNode)
                    }

                    Section(LocalizedStringResource("dom.element.section.selector", bundle: .module)) {
                        selectorRow(selectedNode: selectedNode)
                    }

                    Section(LocalizedStringResource("dom.element.section.attributes", bundle: .module)) {
                        attributesSection(selectedNode: selectedNode)
                    }
                }
                .listStyle(.inset)
            } else {
                emptyState
            }
        }
        .sheet(item: $draftSession, onDismiss: { clearDraftSession() }) { session in
            VStack(alignment: .leading, spacing: 12) {
                Text(wiLocalized("dom.element.attributes.edit", default: "Edit Attribute"))
                    .font(.headline)
                Text(session.key.attributeName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                TextField(
                    wiLocalized("dom.element.attributes.value", default: "Value"),
                    text: Binding(
                        get: { draftSession?.draftValue ?? "" },
                        set: { updateDraft($0) }
                    )
                )
                .disabled(isDraftSaveInFlight)
                HStack {
                    Spacer()
                    Button(wiLocalized("cancel", default: "Cancel")) {
                        clearDraftSession()
                    }
                    .disabled(isDraftSaveInFlight)
                    Button(wiLocalized("save", default: "Save")) {
                        saveDraft()
                    }
                    .disabled(isDraftSaveInFlight)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(minWidth: 320)
        }
        .onChange(of: selectedNode?.id) { _, _ in
            reconcileDraftSession(allowTransientDeselection: true)
        }
        .onChange(of: selectedNode?.attributes) { _, _ in
            reconcileDraftSession(allowTransientDeselection: false)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(.secondary)
        } description: {
            VStack(spacing: 4) {
                Text(wiLocalized("dom.element.select_prompt"))
                Text(wiLocalized("dom.element.hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewRow(selectedNode: DOMNodeModel) -> some View {
        Text(selectedNode.preview)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
    }

    private func selectorRow(selectedNode: DOMNodeModel) -> some View {
        Text(selectedNode.selectorPath)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
    }

    @ViewBuilder
    private func attributesSection(selectedNode: DOMNodeModel) -> some View {
        if selectedNode.attributes.isEmpty {
            infoRow(message: wiLocalized("dom.element.attributes.empty"), color: .secondary)
        } else {
            ForEach(selectedNode.attributes, id: \.name) { attribute in
                VStack(alignment: .leading, spacing: 6) {
                    Text(attribute.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(attributeValue(for: attribute, selectedNode: selectedNode))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
                .contextMenu {
                    Button(wiLocalized("dom.element.attributes.edit", default: "Edit Attribute")) {
                        beginDraft(attribute: attribute, selectedNode: selectedNode)
                    }
                    Button(wiLocalized("dom.element.attributes.delete", default: "Delete Attribute"), role: .destructive) {
                        deleteAttribute(attribute: attribute, selectedNode: selectedNode)
                    }
                }
            }
        }
    }

    private func beginDraft(attribute: DOMAttribute, selectedNode: DOMNodeModel) {
        let key = WIDOMAttributeDraftKey(nodeID: selectedNode.id, attributeName: attribute.name)
        if draftSession?.key == key {
            return
        }
        draftSession = .init(key: key, value: attribute.value)
    }

    private func updateDraft(_ value: String) {
        guard var draftSession else {
            return
        }
        draftSession.updateDraft(value)
        self.draftSession = draftSession
    }

    private func clearDraftSession() {
        pendingDraftSelectionClearTask?.cancel()
        pendingDraftSelectionClearTask = nil
        isDraftSaveInFlight = false
        draftSession = nil
    }

    private func deleteAttribute(attribute: DOMAttribute, selectedNode: DOMNodeModel) {
        let key = WIDOMAttributeDraftKey(nodeID: selectedNode.id, attributeName: attribute.name)
        let preservedDraftSession = draftSession?.key == key ? draftSession : nil
        let inspector = inspector
        Task {
            let result = await inspector.removeAttribute(nodeID: selectedNode.id, name: attribute.name)
            await MainActor.run {
                if result == .applied {
                    if self.draftSession?.key == key {
                        self.clearDraftSession()
                    }
                    return
                }
                guard let preservedDraftSession, self.selectedNode?.id == key.nodeID else {
                    return
                }
                if self.selectedNode?.attributes.contains(where: { $0.name == key.attributeName }) == true {
                    self.draftSession = preservedDraftSession
                }
            }
        }
    }

    private func saveDraft() {
        guard !isDraftSaveInFlight, let draftSession else {
            return
        }
        isDraftSaveInFlight = true
        let key = draftSession.key
        let submittedValue = draftSession.draftValue
        let inspector = inspector
        Task {
            let result = await inspector.setAttribute(
                nodeID: key.nodeID,
                name: key.attributeName,
                value: submittedValue
            )
            await MainActor.run {
                self.isDraftSaveInFlight = false
                guard result == .applied else {
                    return
                }
                self.draftSession = resolveAttributeSheetDraftSessionAfterSuccessfulSave(
                    self.draftSession,
                    key: key,
                    submittedValue: submittedValue
                )
            }
        }
    }

    private func reconcileDraftSession(allowTransientDeselection: Bool) {
        pendingDraftSelectionClearTask?.cancel()
        pendingDraftSelectionClearTask = nil

        guard let draftSession else {
            return
        }

        switch reconcileAttributeDraftSession(
            draftSession,
            selectedNode: selectedNode,
            allowTransientDeselection: allowTransientDeselection
        ) {
        case let .keep(updatedSession):
            self.draftSession = updatedSession
        case .clear:
            self.draftSession = nil
        case .deferClear:
            pendingDraftSelectionClearTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else {
                    return
                }
                pendingDraftSelectionClearTask = nil
                reconcileDraftSession(allowTransientDeselection: false)
            }
        }
    }

    private func attributeValue(for attribute: DOMAttribute, selectedNode: DOMNodeModel) -> String {
        let key = WIDOMAttributeDraftKey(nodeID: selectedNode.id, attributeName: attribute.name)
        guard draftSession?.key == key else {
            return attribute.value
        }
        return draftSession?.draftValue ?? attribute.value
    }

    private func infoRow(message: String, color: Color) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Detail Empty (AppKit)") {
    WIAppKitPreviewContainer {
        WIDOMDetailViewController(inspector: WIDOMPreviewFixtures.makeInspector(mode: .empty))
    }
}

#Preview("DOM Detail Selected (AppKit)") {
    WIAppKitPreviewContainer {
        WIDOMDetailViewController(inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected))
    }
}
#endif

#endif
