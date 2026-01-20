import Foundation
import SwiftUI

struct WINetworkBodySectionView: View {
    let entry: WINetworkEntry
    let viewModel: WINetworkViewModel
    let bodyState: WINetworkBody

    var body: some View {
        NavigationLink {
            WINetworkBodyPreviewView(entry: entry, viewModel: viewModel, bodyState: bodyState)
        }label:{
            VStack(spacing:8){
                metadataBlock
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                bodyPreviewContent
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if case let .failed(error) = bodyState.fetchState {
                    Text(error.localizedResource)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                    
            }
            .animation(.easeInOut(duration: 0.16), value: bodyState.fetchState)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(networkListRowBackground)
        .scenePadding(.horizontal)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(.init())
        
    }

    @ViewBuilder
    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metadataItems
                }
                VStack(alignment: .leading, spacing: 6) {
                    metadataItems
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let summary = bodyState.summary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        if let typeLabel = bodyTypeLabel {
            Label {
                Text(verbatim: typeLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "doc.text")
            }
        }
        if let sizeLabel = bodySizeLabel {
            Label {
                Text(verbatim: sizeLabel)
            } icon: {
                Image(systemName: "ruler")
            }
        }
    }

    private var bodyPreviewContent: some View {
        Group {
            if bodyState.kind == .form, !bodyState.formEntries.isEmpty {
                formPreview
            } else if let previewText {
                Text(verbatim: previewText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(10)
            } else {
                Text("network.body.unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formPreviewEntries: [WINetworkBody.FormEntry] {
        Array(bodyState.formEntries.prefix(4))
    }

    private var formPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(formPreviewEntries.indices, id: \.self) { index in
                let entry = formPreviewEntries[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: entry.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: formEntryValue(entry))
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var bodyTypeLabel: String? {
        let headerValue: String?
        switch bodyState.role {
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
        return bodyState.kind.rawValue.uppercased()
    }

    private var bodySizeLabel: String? {
        guard let size = bodySize else {
            return nil
        }
        return formatBytes(size)
    }

    private var bodySize: Int? {
        if let size = bodyState.size {
            return size
        }
        switch bodyState.role {
        case .request:
            return entry.requestBodyBytesSent
        case .response:
            return entry.decodedBodyLength ?? entry.encodedBodyLength
        }
    }

    private var previewText: String? {
        if bodyState.kind == .binary {
            return bodyState.displayText
        }
        return decodedText(from: bodyState) ?? bodyState.displayText
    }

    private func decodedText(from body: WINetworkBody) -> String? {
        guard body.kind != .binary else {
            return nil
        }
        guard let candidate = body.full ?? body.preview else {
            return nil
        }
        guard body.isBase64Encoded else {
            return candidate
        }
        guard let data = Data(base64Encoded: candidate) else {
            return nil
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func formEntryValue(_ entry: WINetworkBody.FormEntry) -> String {
        if entry.isFile, let fileName = entry.fileName, !fileName.isEmpty {
            return fileName
        }
        return entry.value
    }

    private func formatBytes(_ length: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(length))
    }
}
