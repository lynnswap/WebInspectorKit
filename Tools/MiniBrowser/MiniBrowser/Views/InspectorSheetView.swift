import SwiftUI
import WebKit
import WebInspectorKit

struct InspectorSheetView: View {
    var model: BrowserViewModel
    var inspectorModel: WebInspectorModel
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        WebInspectorView(inspectorModel, webView: model.webView)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .background(backgroundColor.opacity(0.5))
        
    }
    private var backgroundColor: Color {
        if let underPageBackgroundColor = model.underPageBackgroundColor{
            return underPageBackgroundColor
        } else if colorScheme == .dark {
            return Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255)
        } else {
            return Color.white
        }
    }
}
