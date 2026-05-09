import WebInspectorEngine

extension NetworkBody.FetchError {
    var localizedDescriptionText: String {
        switch self {
        case .unavailable:
            wiLocalized("network.body.fetch.error.unavailable")
        case .decodeFailed:
            wiLocalized("network.body.fetch.error.decode_failed")
        case .unknown:
            wiLocalized("network.body.fetch.error.unknown")
        }
    }
}
