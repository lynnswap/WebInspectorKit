import Foundation

#if canImport(UIKit)
import UIKit

enum WIUIStyle {
    enum iOS {
        static var monospaceFont: UIFont {
            .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }
}

#elseif canImport(AppKit)
import AppKit

enum WIUIStyle {
    enum macOS {
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 12
        static let sectionSpacing: CGFloat = 12
        static let rowSpacing: CGFloat = 8
        static let cardCornerRadius: CGFloat = 10

        static var cardBorderColor: NSColor { .separatorColor.withAlphaComponent(0.3) }
        static var headerFont: NSFont { .systemFont(ofSize: 22, weight: .semibold) }
        static var bodyFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
        static var detailFont: NSFont { .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
    }
}

#endif
