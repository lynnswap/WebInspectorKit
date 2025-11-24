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
                    Text("Element" as String)
                }
                Section{
                    if selection.attributes.isEmpty {
                        Text("dom.detail.attributes.empty")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selection.attributes,id:\.self) { element in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(element.name)
                                    .font(.subheadline.weight(.semibold))
                                SelectionPreviewTextRepresentable(
                                    text: element.value,
                                    textStyle: .footnote,
                                    textColor: .secondaryLabel
                                )
                            }
                            .listRowStyle()
                        }
                    }
                }header:{
                    Text("Attributes" as String)
                }
            }
            .listSectionSeparatorTint(.clear)
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
#endif
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

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, textStyle: textStyle, textColor: textColor)
    }

    func makeUIView(context: Context) -> SelectionUITextView {
        context.coordinator.textView
    }

    func updateUIView(_ textView: SelectionUITextView, context: Context) {
        context.coordinator.update(text: text)
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

        init(text: String, textStyle: UIFont.TextStyle, textColor: UIColor) {
            let textView = SelectionUITextView()
            textView.applyStyle(textStyle: textStyle, textColor: textColor)
            textView.apply(text: text)
            self.textView = textView
        }

        func update(text: String) {
            textView.apply(text: text)
        }
    }
}

public final class SelectionUITextView: UITextView {
    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        textColor = .label
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
        if self.text != text {
            self.text = text
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
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
            WIDOMAttribute(name: "class", value: "entry card is-selected"),
            WIDOMAttribute(name: "data-testid", value: "postText"),
            WIDOMAttribute(name: "role", value: "article")
        ],
        path: [
            "html",
            "body.app-layout",
            "main.timeline",
            "section.thread",
            "article.entry"
        ]
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
        ]
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
