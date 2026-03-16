#if os(iOS) && DEBUG
import SwiftUI

struct NativeInspectorProbeResultSheet: View {
    let result: NativeInspectorProbeResult?
    let isRunning: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isRunning {
                        ProgressView("Running native-only probe…")
                    }

                    if let result {
                        field("Status", value: statusText(for: result.status))
                        field("Stage", value: result.stage)
                        field("Message", value: result.message)
                        field("URL", value: result.urlString)
                        field("Request ID", value: result.requestIdentifier)
                        field("Base64", value: result.bodyPreview == nil ? nil : String(result.base64Encoded))
                        field("Inspector Error", value: result.rawBackendError)
                        field("Body Preview", value: result.bodyPreview, monospaced: true)
                        field("Raw Message", value: result.rawMessage, monospaced: true)
                    } else {
                        Text("No probe result yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Native Probe")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func field(_ title: String, value: String?, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            if let value, !value.isEmpty {
                Text(value)
                    .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("n/a")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(for status: NativeInspectorProbeStatus) -> String {
        switch status {
        case .running:
            "running"
        case .succeeded:
            "succeeded"
        case .failed:
            "failed"
        }
    }
}
#endif
