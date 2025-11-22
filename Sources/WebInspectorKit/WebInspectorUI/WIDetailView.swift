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

                            Text(selection.preview)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)

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
