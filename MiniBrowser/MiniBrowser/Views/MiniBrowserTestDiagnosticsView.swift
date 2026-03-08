import SwiftUI

struct MiniBrowserTestDiagnosticsView: View {
    let model: BrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("terminationCount=\(model.webContentTerminationCount)")
                .accessibilityIdentifier("MiniBrowser.diagnostics.terminationCount")
            Text("didFinishCount=\(model.didFinishNavigationCount)")
                .accessibilityIdentifier("MiniBrowser.diagnostics.didFinishCount")
            Text("currentURL=\(model.currentURL?.absoluteString ?? "n/a")")
                .lineLimit(2)
                .accessibilityIdentifier("MiniBrowser.diagnostics.currentURL")
            Text("lastError=\(model.lastNavigationErrorDescription ?? "n/a")")
                .lineLimit(2)
                .accessibilityIdentifier("MiniBrowser.diagnostics.lastNavigationError")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("MiniBrowser.diagnostics.panel")
    }
}
