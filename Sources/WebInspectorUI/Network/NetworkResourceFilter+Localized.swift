import WebInspectorEngine

extension NetworkResourceFilter {
    var localizedTitle: String {
        switch self {
        case .all:
            wiLocalized("network.filter.all", default: "All")
        case .document:
            wiLocalized("network.filter.document", default: "Document")
        case .stylesheet:
            wiLocalized("network.filter.stylesheet", default: "Stylesheet")
        case .image:
            wiLocalized("network.filter.image", default: "Image")
        case .font:
            wiLocalized("network.filter.font", default: "Font")
        case .script:
            wiLocalized("network.filter.script", default: "Script")
        case .xhrFetch:
            wiLocalized("network.filter.xhr_fetch", default: "XHR/Fetch")
        case .other:
            wiLocalized("network.filter.other", default: "Other")
        }
    }
}
