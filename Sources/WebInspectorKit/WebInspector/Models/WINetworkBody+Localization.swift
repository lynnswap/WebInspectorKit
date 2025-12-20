import SwiftUI

extension WINetworkBody.FetchError {
    var localizedResource: LocalizedStringResource {
        switch self {
        case .unavailable:
            return LocalizedStringResource("network.body.fetch.error.unavailable", bundle: .module)
        case .decodeFailed:
            return LocalizedStringResource("network.body.fetch.error.decode_failed", bundle: .module)
        case .unknown:
            return LocalizedStringResource("network.body.fetch.error.unknown", bundle: .module)
        }
    }
}
