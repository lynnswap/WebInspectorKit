import WebInspectorEngine

extension NetworkResourceFilter {
    var localizedTitle: String {
        switch self {
        case .all:
            return wiLocalized("network.filter.all", default: "All")
        case .document:
            return wiLocalized("network.filter.document", default: "Document")
        case .stylesheet:
            return wiLocalized("network.filter.stylesheet", default: "Stylesheet")
        case .image:
            return wiLocalized("network.filter.image", default: "Image")
        case .font:
            return wiLocalized("network.filter.font", default: "Font")
        case .script:
            return wiLocalized("network.filter.script", default: "Script")
        case .xhrFetch:
            return wiLocalized("network.filter.xhr_fetch", default: "XHR/Fetch")
        case .other:
            return wiLocalized("network.filter.other", default: "Other")
        }
    }
}
