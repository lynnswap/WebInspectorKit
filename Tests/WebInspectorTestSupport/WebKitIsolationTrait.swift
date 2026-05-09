import Testing

public struct WebKitIsolationTrait: TestTrait, SuiteTrait, TestScoping {
    public let isRecursive = true

    public init() {}

    public func provideScope(
        for test: Testing.Test,
        testCase: Testing.Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withWebKitTestIsolation {
            try await function()
        }
    }
}

extension Trait where Self == WebKitIsolationTrait {
    public static var webKitIsolated: Self {
        .init()
    }
}
