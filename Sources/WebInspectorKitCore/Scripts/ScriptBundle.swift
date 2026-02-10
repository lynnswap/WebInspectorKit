import Foundation

enum ScriptBundle {
    static func source(named name: String) -> String? {
        BundledJavaScriptData.scripts[name]
    }
}
