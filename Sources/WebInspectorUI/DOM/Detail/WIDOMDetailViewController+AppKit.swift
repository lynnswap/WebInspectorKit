import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit
import ObservationBridge
import SwiftUI

@MainActor
public final class WIDOMDetailViewController: NSViewController {
    private let inspector: WIDOMModel
    private var hostingController: NSHostingController<ElementDetailsMacRootView>?
    private var observationHandles: Set<ObservationHandle> = []
    private var renderRefreshCount = 0

    public init(inspector: WIDOMModel) {
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

        startObservingInspectorState()
    }

    private func startObservingInspectorState() {
        inspector.observe(\.graphProjectionRevision, options: [.removeDuplicates]) { [weak self] _ in
            self?.refreshRootView()
        }
        .store(in: &observationHandles)

        inspector.observe(\.errorMessage, options: [.removeDuplicates]) { [weak self] _ in
            self?.refreshRootView()
        }
        .store(in: &observationHandles)
    }

    private func refreshRootView() {
        renderRefreshCount += 1
        hostingController?.rootView = ElementDetailsMacRootView(inspector: inspector)
        hostingController?.view.layoutSubtreeIfNeeded()
    }

    var testRenderRefreshCount: Int {
        renderRefreshCount
    }
}

@MainActor
private struct ElementDetailsMacRootView: View {
    private struct AttributeEditorState: Identifiable {
        let nodeID: DOMEntryID?
        let name: String
        let initialValue: String

        var id: String {
            let nodeID = nodeID?.nodeID ?? 0
            return "\(nodeID):\(name)"
        }
    }

    @Bindable var inspector: WIDOMModel
    @State private var attributeEditorState: AttributeEditorState?
    @State private var attributeEditorDraft = ""

    private var selectedEntry: DOMEntry? {
        inspector.selectedEntry
    }

    private var hasSelection: Bool {
        selectedEntry != nil
    }

    var body: some View {
        if hasSelection {
            List {
                if let errorMessage = inspector.errorMessage, !errorMessage.isEmpty {
                    Section {
                        infoRow(message: errorMessage, color: .orange)
                    }
                }

                Section(LocalizedStringResource("dom.element.section.element", bundle: .module)) {
                    previewRow
                }

                Section(LocalizedStringResource("dom.element.section.selector", bundle: .module)) {
                    selectorRow
                }

                Section(LocalizedStringResource("dom.element.section.styles", bundle: .module)) {
                    stylesSection
                }

                Section(LocalizedStringResource("dom.element.section.attributes", bundle: .module)) {
                    attributesSection
                }
            }
            .listStyle(.inset)
            .sheet(item: $attributeEditorState) { state in
                VStack(alignment: .leading, spacing: 12) {
                    Text(wiLocalized("dom.element.attributes.edit", default: "Edit Attribute"))
                        .font(.headline)
                    Text(state.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    TextField(
                        wiLocalized("dom.element.attributes.value", default: "Value"),
                        text: $attributeEditorDraft
                    )
                    HStack {
                        Spacer()
                        Button(wiLocalized("cancel", default: "Cancel")) {
                            attributeEditorState = nil
                        }
                        Button(wiLocalized("save", default: "Save")) {
                            inspector.updateAttributeValue(name: state.name, value: attributeEditorDraft)
                            attributeEditorState = nil
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(minWidth: 320)
                .onAppear {
                    attributeEditorDraft = state.initialValue
                }
            }
        } else {
            emptyState
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

    private var previewRow: some View {
        Text(selectedEntry?.preview ?? "")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
    }

    private var selectorRow: some View {
        Text(selectedEntry?.selectorPath ?? "")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
    }

    @ViewBuilder
    private var stylesSection: some View {
        if selectedEntry?.isLoadingMatchedStyles == true {
            infoRow(message: wiLocalized("dom.element.styles.loading"), color: .secondary)
        } else if (selectedEntry?.matchedStyles ?? []).isEmpty {
            infoRow(message: wiLocalized("dom.element.styles.empty"), color: .secondary)
        } else {
            ForEach(Array((selectedEntry?.matchedStyles ?? []).enumerated()), id: \.offset) { _, rule in
                VStack(alignment: .leading, spacing: 8) {
                    Text(rule.selectorText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(styleRuleDetail(rule))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
            }

            if selectedEntry?.matchedStylesTruncated == true {
                infoRow(message: wiLocalized("dom.element.styles.truncated"), color: .secondary)
            }
            if let blockedStylesheetCount = selectedEntry?.blockedStylesheetCount, blockedStylesheetCount > 0 {
                infoRow(
                    message: "\(blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))",
                    color: .secondary
                )
            }
        }
    }

    @ViewBuilder
    private var attributesSection: some View {
        if (selectedEntry?.attributes ?? []).isEmpty {
            infoRow(message: wiLocalized("dom.element.attributes.empty"), color: .secondary)
        } else {
            let attributes = selectedEntry?.attributes ?? []
            ForEach(Array(attributes.enumerated()), id: \.offset) { _, attribute in
                VStack(alignment: .leading, spacing: 6) {
                    Text(attribute.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(attribute.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
                .contextMenu {
                    Button(wiLocalized("dom.element.attributes.edit", default: "Edit Attribute")) {
                        attributeEditorState = AttributeEditorState(
                            nodeID: selectedEntry?.id,
                            name: attribute.name,
                            initialValue: attribute.value
                        )
                        attributeEditorDraft = attribute.value
                    }
                    Button(wiLocalized("dom.element.attributes.delete", default: "Delete Attribute"), role: .destructive) {
                        inspector.removeAttribute(name: attribute.name)
                    }
                }
            }
        }
    }

    private func styleRuleDetail(_ rule: DOMMatchedStyleRule) -> String {
        var parts: [String] = []
        if !rule.sourceLabel.isEmpty {
            parts.append(rule.sourceLabel)
        }
        if !rule.atRuleContext.isEmpty {
            parts.append(contentsOf: rule.atRuleContext)
        }
        let declarations = rule.declarations.map { declaration in
            let importantSuffix = declaration.important ? " !important" : ""
            return "\(declaration.name): \(declaration.value)\(importantSuffix);"
        }.joined(separator: "\n")
        if !declarations.isEmpty {
            parts.append(declarations)
        }
        return parts.joined(separator: "\n")
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
