import Foundation

package actor WITransportCodec {
    package static let shared = WITransportCodec()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    package func encode<Parameters: Encodable>(_ parameters: Parameters) throws -> Data? {
        do {
            let data = try encoder.encode(parameters)
            if data == Data("{}".utf8) {
                return nil
            }
            return data
        } catch {
            throw WITransportError.invalidCommandEncoding(error.localizedDescription)
        }
    }

    package func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw WITransportError.invalidResponse(error.localizedDescription)
        }
    }
}
