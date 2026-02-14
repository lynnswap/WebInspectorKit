import SwiftUI
import Observation
import WebInspectorKitCore

extension WebInspector {
    public struct ElementDetailsView: View {
        private let inspector: DOMInspector

        public init(inspector: DOMInspector) {
            self.inspector = inspector
        }

        public var body: some View {
            Group {
                if inspector.selection.nodeId != nil {
                    List {
                        Section {
                            selectionText(inspector.selection.preview)
                                .listRowStyle()
                        } header: {
                            Text(LocalizedStringResource("dom.element.section.element", bundle: .module))
                        }

                        Section {
                            selectionText(inspector.selection.selectorPath)
                                .listRowStyle()
                        } header: {
                            Text(LocalizedStringResource("dom.element.section.selector", bundle: .module))
                        }

                        Section {
                            if inspector.selection.attributes.isEmpty {
                                Text(LocalizedStringResource("dom.element.attributes.empty", bundle: .module))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .listRowSeparator(.hidden)
                            } else {
                                ForEach(inspector.selection.attributes) { element in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(element.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        attributeValueEditor(element)
                                    }
                                    .listRowStyle()
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        deleteButton(element)
                                            .labelStyle(.iconOnly)
                                    }
                                    .contextMenu {
                                        deleteButton(element)
                                    }
                                }
                            }
                        } header: {
                            Text(LocalizedStringResource("dom.element.section.attributes", bundle: .module))
                        }
                    }
                    .listSectionSeparator(.hidden)
                    .listStyle(.plain)
#if canImport(UIKit)
                    .listRowSpacing(8)
                    .listSectionSpacing(12)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .contentMargins(.bottom, 24, for: .scrollContent)
#endif
                } else {
                    ContentUnavailableView(
                        String(localized: "dom.element.select_prompt", bundle: .module),
                        systemImage: "cursorarrow.rays",
                        description: Text(LocalizedStringResource("dom.element.hint", bundle: .module))
                    )
                }
            }
            .animation(.easeInOut(duration: 0.12), value: inspector.selection.nodeId == nil)
        }

        @ViewBuilder
        private func selectionText(_ text: String) -> some View {
#if canImport(UIKit)
            SelectionPreviewTextRepresentable(
                text: text,
                textStyle: .footnote,
                textColor: .label
            )
#else
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
#endif
        }

        @ViewBuilder
        private func attributeValueEditor(_ element: DOMAttribute) -> some View {
#if canImport(UIKit)
            SelectionPreviewTextRepresentable(
                text: element.value,
                textStyle: .footnote,
                textColor: .label,
                isEditable: true,
                onChange: { newValue in
                    inspector.updateAttributeValue(name: element.name, value: newValue)
                }
            )
#else
            NonUIKitAttributeValueEditor(
                element: element,
                update: { newValue in
                    inspector.updateAttributeValue(name: element.name, value: newValue)
                }
            )
#endif
        }

        private func deleteButton(_ element: DOMAttribute) -> some View {
            Button(role: .destructive) {
                inspector.removeAttribute(name: element.name)
            } label: {
                Label {
                    Text(LocalizedStringResource("delete", bundle: .module))
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }
}

private extension View {
    func listRowStyle() -> some View {
        self
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(listRowBackground)
            .scenePadding(.horizontal)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(.init())
    }

    @ViewBuilder
    private var listRowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.secondary.opacity(0.15))
        }
    }
}

#if !canImport(UIKit)
private struct NonUIKitAttributeValueEditor: View {
    let element: DOMAttribute
    let update: (String) -> Void

    @State private var text: String
    @State private var debounceTask: Task<Void, Never>?

    init(element: DOMAttribute, update: @escaping (String) -> Void) {
        self.element = element
        self.update = update
        _text = State(initialValue: element.value)
    }

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .font(.system(.footnote, design: .monospaced))
            .textFieldStyle(.plain)
            .textSelection(.enabled)
            .onChange(of: element.value) { _, newValue in
                guard newValue != text else { return }
                text = newValue
            }
            .onChange(of: text) { _, newValue in
                guard newValue != element.value else { return }
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    update(newValue)
                }
            }
            .onDisappear {
                debounceTask?.cancel()
                debounceTask = nil
            }
    }
}
#endif

#if canImport(UIKit)
private struct SelectionPreviewTextRepresentable: UIViewRepresentable {
    var text: String
    var textStyle: UIFont.TextStyle
    var textColor: UIColor
    var isEditable: Bool = false
    var onChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: text,
            textStyle: textStyle,
            textColor: textColor,
            isEditable: isEditable,
            onChange: onChange
        )
    }

    func makeUIView(context: Context) -> SelectionUITextView {
        context.coordinator.textView
    }

    func updateUIView(_ textView: SelectionUITextView, context: Context) {
        context.coordinator.update(text: text, onChange: onChange)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectionUITextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? uiView.bounds.width
        let targetWidth = proposedWidth > 0 ? proposedWidth : UIScreen.main.bounds.width
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: targetWidth, height: fittingSize.height)
    }
    @MainActor
    final class Coordinator {
        let textView: SelectionUITextView

        init(
            text: String,
            textStyle: UIFont.TextStyle,
            textColor: UIColor,
            isEditable: Bool,
            onChange: ((String) -> Void)?
        ) {
            let textView = SelectionUITextView(isEditable: isEditable)
            textView.applyStyle(textStyle: textStyle, textColor: textColor)
            textView.onChange = onChange
            textView.apply(text: text)
            self.textView = textView
        }

        func update(text: String, onChange: ((String) -> Void)?) {
            textView.onChange = onChange
            textView.apply(text: text)
        }
    }
}

public final class SelectionUITextView: UITextView, UITextViewDelegate {
    private let initialEditable: Bool

    public convenience init(isEditable: Bool) {
        self.init(isEditable: isEditable, frame: .zero, textContainer: nil)
    }

    public init(
        isEditable: Bool,
        frame: CGRect = .zero,
        textContainer: NSTextContainer? = nil
    ) {
        self.initialEditable = isEditable
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        self.initialEditable = true
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        isEditable = initialEditable
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        textColor = .label
        returnKeyType = .done
        delegate = initialEditable ? self : nil
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func applyStyle(textStyle: UIFont.TextStyle, textColor: UIColor) {
        font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: textStyle).pointSize,
            weight: .regular
        )
        self.textColor = textColor
    }

    func apply(text: String) {
        guard self.text != text else { return }
        self.text = text
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }

    public func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        }
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        onChange?(textView.text ?? "")
    }

    var onChange: ((String) -> Void)?
}
#endif


#if DEBUG
@MainActor
private func makeElementDetailsPreviewInspector(selection: DOMSelection?) -> WebInspector.DOMInspector {
    let inspector = WebInspector.DOMInspector(session: DOMSession())
    if let selection {
        inspector.selection.nodeId = selection.nodeId
        inspector.selection.preview = selection.preview
        inspector.selection.attributes = selection.attributes
        inspector.selection.path = selection.path
        inspector.selection.selectorPath = selection.selectorPath
    } else {
        inspector.selection.clear()
    }
    return inspector
}

@MainActor
private enum ElementDetailsPreviewData {
    static let selected = DOMSelection(
        nodeId: 128,
        preview: "<article class=\"entry\">Preview post content</article>",
        attributes: [
            DOMAttribute(nodeId: 128, name: "class", value: "entry card is-selected"),
            DOMAttribute(nodeId: 128, name: "data-testid", value: "postText"),
            DOMAttribute(nodeId: 128, name: "role", value: "article")
        ],
        path: [
            "html",
            "body.app-layout",
            "main.timeline",
            "section.thread",
            "article.entry"
        ],
        selectorPath: "html > body.app-layout > main.timeline > section.thread > article.entry"
    )

    static let attributesEmpty = DOMSelection(
        nodeId: 256,
        preview: "<section class=\"placeholder\">No attributes here</section>",
        attributes: [],
        path: [
            "html",
            "body.app-layout",
            "main.timeline",
            "section.thread",
            "article.entry"
        ],
        selectorPath: "html > body.app-layout > main.timeline > section.thread > article.entry"
    )
}

#Preview("DOM Selected") {
    WebInspector.ElementDetailsView(inspector: makeElementDetailsPreviewInspector(selection: ElementDetailsPreviewData.selected))
}

#Preview("Attributes Empty") {
    WebInspector.ElementDetailsView(inspector: makeElementDetailsPreviewInspector(selection: ElementDetailsPreviewData.attributesEmpty))
}

#Preview("No DOM Selection") {
    WebInspector.ElementDetailsView(inspector: makeElementDetailsPreviewInspector(selection: nil))
}
#endif
