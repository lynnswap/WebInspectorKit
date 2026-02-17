import SwiftUI
import WebInspectorKit

struct InspectorSheetView: View {
    var model: BrowserViewModel
    var inspectorController: WebInspector.Controller

    @Environment(\.colorScheme) private var colorScheme
#if os(iOS)
    @Environment(\.dismiss) private var dismiss
#endif

    var body: some View {
        WebInspector.Panel(inspectorController, webView: model.webView)
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
#endif
            .background(backgroundColor.opacity(0.5))
    }

    private var backgroundColor: Color {
        if let underPageBackgroundColor = model.underPageBackgroundColor {
            return underPageBackgroundColor
        } else if colorScheme == .dark {
            return Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255)
        } else {
            return Color.white
        }
    }
}
