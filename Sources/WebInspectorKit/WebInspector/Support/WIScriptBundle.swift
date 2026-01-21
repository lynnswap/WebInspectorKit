import Foundation

enum WIScriptBundle {
    static func source(named name: String) -> String? {
        BundledJavaScriptData.scripts[name]
    }
}
