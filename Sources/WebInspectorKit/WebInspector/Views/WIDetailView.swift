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
        if let selection = model.webBridge.domSelection {
            List{
                Section{
                    VStack(alignment: .leading, spacing: 8) {
                        if !selection.path.isEmpty {
                            Text(selection.path.joined(separator: " › "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        SelectionPreviewTextRepresentable(
                            textView: selection.previewView,
                            textStyle: .body,
                            textColor: .label
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(listRowBackground)
                    .scenePadding(.horizontal)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init())
                }header: {
                    Text("dom.detail.selected_title")
                }
                Section{
                    if selection.attributes.isEmpty {
                        Text("dom.detail.attributes.empty")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(selection.attributes.enumerated()), id: \.offset) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.element.name)
                                    .font(.subheadline.weight(.semibold))
                                SelectionPreviewTextRepresentable(
                                    textView: entry.element.valueView,
                                    textStyle: .footnote,
                                    textColor: .secondaryLabel
                                )
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(listRowBackground)
                            .scenePadding(.horizontal)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init())
                            
                        }
                    }
                }header:{
                    Text("dom.detail.attributes")
                }
                .listSectionSeparatorTint(.clear)
            }
            .listStyle(.plain)
            .listRowSpacing(8)
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
    var textView: SelectionUITextView
    var textStyle: UIFont.TextStyle
    var textColor: UIColor

    func makeUIView(context: Context) -> SelectionUITextView {
        textView.applyStyle(textStyle: textStyle, textColor: textColor)
        return textView
    }

    func updateUIView(_ textView: SelectionUITextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectionUITextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? uiView.bounds.width
        let targetWidth = proposedWidth > 0 ? proposedWidth : UIScreen.main.bounds.width
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: targetWidth, height: fittingSize.height)
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
    model.webBridge.domSelection = selection
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
