import Foundation

@inline(__always)
func monoclyLocalized(_ key: String.LocalizationValue) -> String {
    String(localized: LocalizedStringResource(key, bundle: .main))
}
