package struct InspectorError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }

    package var description: String {
        message
    }
}
