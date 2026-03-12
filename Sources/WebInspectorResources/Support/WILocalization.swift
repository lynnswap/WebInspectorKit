import Foundation

@inline(__always)
package func wiLocalized(_ key: String, default defaultValue: String? = nil) -> String {
    let resolved = NSLocalizedString(key, bundle: .module, comment: "")
    if resolved == key, let defaultValue {
        return defaultValue
    }
    return resolved
}

package extension Bundle {
    static var webInspectorResources: Bundle {
        .module
    }
}
