import WebInspectorKitCore

extension NetworkBody.FetchError {
    var localizedDescriptionText: String {
        switch self {
        case .unavailable:
            return wiLocalized("network.body.fetch.error.unavailable")
        case .decodeFailed:
            return wiLocalized("network.body.fetch.error.decode_failed")
        case .unknown:
            return wiLocalized("network.body.fetch.error.unknown")
        }
    }
}
