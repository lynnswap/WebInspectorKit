//
//  WIDetailView.swift
//  WebInspectorKit
//
//  Created by Codex on 2024/12/08.
//

import SwiftUI
import Observation

public struct WIDetailView: View {
    private var model: WIViewModel

    public init(
        _ viewModel: WIViewModel
    ) {
        self.model = viewModel
    }
    public var body: some View {
#if canImport(UIKit)
        let selection = model.webBridge.domSelection
        Group{
            if selection.nodeId != nil {
                List{
                    Section{
                        SelectionPreviewTextRepresentable(
                            text: selection.preview,
                            textStyle: .footnote,
                            textColor: .label
                        )
                        .listRowStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }header: {
                        Text("dom.detail.section.element")
                    }
                    Section {
                        SelectionPreviewTextRepresentable(
                            text: selection.selectorPath,
                            textStyle: .footnote,
                            textColor: .label
                        )
                        .listRowStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } header: {
                        Text("dom.detail.section.selector")
                    }
                    Section {
                        if selection.attributes.isEmpty {
                            Text("dom.detail.attributes.empty")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(selection.attributes) { element in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(element.name)
                                        .font(.subheadline.weight(.semibold))
                                    SelectionPreviewTextRepresentable(
                                        text: element.value,
                                        textStyle: .footnote,
                                        textColor: .secondaryLabel,
                                        isEditable: true,
                                        onChange: { newValue in
                                            model.webBridge.updateAttributeValue(name: element.name, value: newValue)
                                        }
                                    )
                                }
                                .listRowStyle()
                                .swipeActions(edge: .trailing, allowsFullSwipe: true){
                                    deleteButton(element)
                                        .labelStyle(.iconOnly)
                                }
                                .contextMenu{
                                    deleteButton(element)
                                }
                            }
                        }
                    }header:{
                        Text("dom.detail.section.attributes")
                    }
                }
                .listSectionSeparator(.hidden)
                .listStyle(.plain)
                .listRowSpacing(8)
                .listSectionSpacing(12)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 24 ,for: .scrollContent)
            }else{
                ContentUnavailableView(
                    String(localized:"dom.detail.select_prompt",bundle:.module),
                    systemImage: "cursorarrow.rays",
                    description: Text("dom.detail.hint")
                )
            }
        }
        .animation(.easeInOut(duration:0.12),value:selection.nodeId == nil)
#endif
    }
   
    private func deleteButton(_ element:WIDOMAttribute) -> some View{
        Button(role:.destructive){
            model.webBridge.removeAttribute(name: element.name)
        }label:{
            Label{
                Text("delete")
            }icon:{
                Image(systemName:"trash")
            }
        }
    }
}

private extension View{
    func listRowStyle() -> some View{
        return self
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
    private var listRowBackground:some View{
        ZStack{
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.secondary.opacity(0.15))
        }
    }
}

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
private func makeWIDetailPreviewModel(selection: WIDOMSelection?) -> WIViewModel {
    let model = WIViewModel()
    if let selection {
        model.webBridge.domSelection = selection
    } else {
        model.webBridge.domSelection.clear()
    }
    return model
}

@MainActor
private enum WIDetailPreviewData {
    static let selected = WIDOMSelection(
        nodeId: 128,
        preview: "<article class=\"entry\">Preview post content</article>",
        attributes: [
            WIDOMAttribute(nodeId: 128, name: "class", value: "entry card is-selected"),
            WIDOMAttribute(nodeId: 128, name: "data-testid", value: "postText"),
            WIDOMAttribute(nodeId: 128, name: "role", value: "article")
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

    static let attributesEmpty = WIDOMSelection(
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
    WIDetailView(makeWIDetailPreviewModel(selection: WIDetailPreviewData.selected))
}

#Preview("Attributes Empty") {
    WIDetailView(makeWIDetailPreviewModel(selection: WIDetailPreviewData.attributesEmpty))
}

#Preview("No DOM Selection") {
    WIDetailView(makeWIDetailPreviewModel(selection: nil))
}
#endif
