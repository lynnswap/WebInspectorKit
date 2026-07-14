package protocol ConnectionBackend: Sendable {
    func sendJSONString(_ message: String) async throws
    func detach() async
}
