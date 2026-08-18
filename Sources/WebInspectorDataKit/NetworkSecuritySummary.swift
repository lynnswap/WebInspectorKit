import WebInspectorProxyKit

package enum NetworkSecuritySummary: Equatable, Sendable {
    package enum PlaintextScheme: Equatable, Sendable {
        case http
        case ws
    }

    package enum EncryptedScheme: Equatable, Sendable {
        case https
        case wss
    }

    package enum Metadata: Equatable, Sendable {
        case notReported
        case reported(Network.Security)
    }

    package enum UnavailableReason: Equatable, Sendable {
        case failedBeforeResponse(reason: String)
        case canceledBeforeResponse(reason: String)
        case completedWithoutResponse
    }

    case plaintextScheme(PlaintextScheme)
    case pending(EncryptedScheme)
    case encryptedScheme(EncryptedScheme, metadata: Metadata)
    case unavailable(EncryptedScheme, reason: UnavailableReason)
    case notApplicable(scheme: String?)
}

package extension NetworkRequest {
    var securitySummary: NetworkSecuritySummary {
        let scheme = Self.rawScheme(in: responseURL ?? url)

        switch Self.classifySecurityScheme(scheme) {
        case let .plaintext(plaintextScheme):
            return .plaintextScheme(plaintextScheme)
        case let .encrypted(encryptedScheme):
            if let security {
                return .encryptedScheme(encryptedScheme, metadata: .reported(security))
            }
            if hasResponse {
                return .encryptedScheme(encryptedScheme, metadata: .notReported)
            }
            switch state {
            case .pending, .responded:
                return .pending(encryptedScheme)
            case let .failed(errorText, canceled):
                let reason: NetworkSecuritySummary.UnavailableReason =
                    if canceled {
                        .canceledBeforeResponse(reason: errorText)
                    } else {
                        .failedBeforeResponse(reason: errorText)
                    }
                return .unavailable(encryptedScheme, reason: reason)
            case .finished:
                return .unavailable(encryptedScheme, reason: .completedWithoutResponse)
            }
        case .other:
            return .notApplicable(scheme: scheme)
        }
    }

    private enum ClassifiedSecurityScheme {
        case plaintext(NetworkSecuritySummary.PlaintextScheme)
        case encrypted(NetworkSecuritySummary.EncryptedScheme)
        case other
    }

    private static func classifySecurityScheme(_ scheme: String?) -> ClassifiedSecurityScheme {
        switch scheme.map(asciiLowercased) {
        case "http":
            return .plaintext(.http)
        case "ws":
            return .plaintext(.ws)
        case "https":
            return .encrypted(.https)
        case "wss":
            return .encrypted(.wss)
        default:
            return .other
        }
    }

    private static func rawScheme(in url: String) -> String? {
        guard let colonIndex = url.firstIndex(of: ":") else {
            return nil
        }
        let scheme = url[..<colonIndex]
        guard let firstByte = scheme.utf8.first, isASCIIAlpha(firstByte) else {
            return nil
        }
        guard scheme.utf8.dropFirst().allSatisfy(isASCIISchemeContinuation) else {
            return nil
        }
        return String(scheme)
    }

    private static func asciiLowercased(_ value: String) -> String {
        String(
            decoding: value.utf8.map { byte in
                switch byte {
                case 0x41...0x5A:
                    byte + 0x20
                default:
                    byte
                }
            }, as: UTF8.self)
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isASCIISchemeContinuation(_ byte: UInt8) -> Bool {
        isASCIIAlpha(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x2B
            || byte == 0x2D
            || byte == 0x2E
    }
}
