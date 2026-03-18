import Foundation
import WebInspectorScriptsGenerated

enum ScriptBundle {
    static func source(named name: String) -> String? {
        CommittedBundledJavaScriptData.scripts[name]
    }
}
