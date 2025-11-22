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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let selection = model.webBridge.domSelection {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("dom.detail.selected_title")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            if !selection.path.isEmpty {
                                Text(selection.path.joined(separator: " › "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            SelectionPreviewTextRepresentable(text: selection.preview)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !selection.description.isEmpty {
                                Text(selection.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.secondary.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.secondary.opacity(0.15))
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("dom.detail.attributes")
                            .font(.headline)

                        if selection.attributes.isEmpty {
                            Text("dom.detail.attributes.empty")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(selection.attributes.enumerated()), id: \.offset) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.element.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(entry.element.value)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(.secondary.opacity(0.12))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(.secondary.opacity(0.15))
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ContentUnavailableView(
                        String(localized:"dom.detail.select_prompt",bundle:.module),
                        systemImage: "cursorarrow.rays",
                        description: Text("dom.detail.hint")
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding()
        }
    }
}

#if canImport(UIKit)
private struct SelectionPreviewTextRepresentable: UIViewRepresentable {
    var text: String

    func makeUIView(context: Context) -> SelectionUITextView {
        SelectionUITextView()
    }

    func updateUIView(_ textView: SelectionUITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectionUITextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? uiView.bounds.width
        let targetWidth = proposedWidth > 0 ? proposedWidth : UIScreen.main.bounds.width
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: targetWidth, height: fittingSize.height)
    }
}

private final class SelectionUITextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
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
        font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}
#elseif canImport(AppKit)
private struct SelectionPreviewTextRepresentable: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> SelectionTextScrollView {
        let scrollView = SelectionTextScrollView()
        let textView = SelectionNSTextView(frame: .zero, textContainer: nil)
        textView.string = text
        scrollView.documentView = textView
        textView.updateContainerSize(for: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: SelectionTextScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SelectionNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.updateContainerSize(for: scrollView)
        scrollView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: SelectionTextScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? SelectionNSTextView else { return nil }
        let proposedWidth = proposal.width ?? scrollView.bounds.width
        let fallbackWidth = NSScreen.main?.visibleFrame.width ?? 800
        let targetWidth = proposedWidth > 0 ? proposedWidth : fallbackWidth
        textView.updateContainerSize(for: scrollView, targetWidth: targetWidth)
        let height = textView.fittingSize.height
        return CGSize(width: targetWidth, height: height)
    }
}

private final class SelectionTextScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        borderType = .noBorder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        documentView?.fittingSize ?? super.intrinsicContentSize
    }
}

private final class SelectionNSTextView: NSTextView {
    override init(frame frameRect: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        drawsBackground = false
        isEditable = false
        isSelectable = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textColor = .labelColor
        font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func updateContainerSize(for scrollView: NSScrollView, targetWidth: CGFloat? = nil) {
        let width = targetWidth ?? max(scrollView.contentSize.width, scrollView.frame.width, 1)
        let containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if textContainer?.containerSize != containerSize {
            textContainer?.containerSize = containerSize
        }
        if frame.size.width != width {
            frame.size.width = width
        }
        let fittingHeight = fittingSize.height
        if frame.size.height != fittingHeight {
            frame.size.height = fittingHeight
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        fittingSize
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
        description: "article.entry#post-128",
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
}

#Preview("DOM Selected") {
    WIDetailView(makeWIDetailPreviewModel(selection: WIDetailPreviewData.selected))
}

#Preview("No DOM Selection") {
    WIDetailView(makeWIDetailPreviewModel(selection: nil))
}
#endif
