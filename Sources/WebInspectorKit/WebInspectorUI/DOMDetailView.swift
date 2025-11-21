//
//  DOMDetailView.swift
//  WebInspectorKit
//
//  Created by Codex on 2024/12/08.
//

import SwiftUI
import Observation

public struct DOMDetailView: View {
    private var model: WebInspectorViewModel

    public init(
        _ viewModel: WebInspectorViewModel
    ) {
        self.model = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selection = model.webBridge.domSelection {
                VStack(alignment: .leading, spacing: 8) {
                    Text("dom.detail.selected_title")
                        .font(.headline)

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

                VStack(alignment: .leading, spacing: 8) {
                    Text("dom.detail.attributes")
                        .font(.headline)

                    if selection.attributes.isEmpty {
                        Text("dom.detail.attributes.empty")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(selection.attributes.enumerated()), id: \.offset) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.element.name)
                                    .font(.subheadline.weight(.medium))
                                Text(entry.element.value)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "dom.detail.select_prompt",
                    systemImage: "cursorarrow.rays",
                    description: Text("dom.detail.hint")
                )
            }
        }
        .padding()
    }
}
