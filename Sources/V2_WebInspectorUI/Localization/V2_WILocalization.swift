import Foundation

@inline(__always)
func v2WILocalized(_ key: String, default defaultValue: String? = nil) -> String {
    defaultValue ?? fallbackLocalizedValue(for: key) ?? key
}

private func fallbackLocalizedValue(for key: String) -> String? {
    switch key {
    case "network.controls.clear":
        "Clear"
    case "network.empty.description":
        "Trigger a network request to see activity."
    case "network.empty.title":
        "No requests yet"
    case "network.filter.all":
        "All"
    case "network.filter.document":
        "Document"
    case "network.filter.stylesheet":
        "Stylesheet"
    case "network.filter.image":
        "Image"
    case "network.filter.font":
        "Font"
    case "network.filter.script":
        "Script"
    case "network.filter.xhr_fetch":
        "XHR/Fetch"
    case "network.filter.other":
        "Other"
    case "network.search.placeholder":
        "Search requests"
    default:
        nil
    }
}
