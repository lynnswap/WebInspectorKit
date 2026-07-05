import Foundation

package protocol TransportBackend: Sendable {
    func sendJSONString(_ message: String) async throws
    func detach() async
}
