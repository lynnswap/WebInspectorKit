package actor ReplyPromise<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuations: [CheckedContinuation<Value, Error>]

    package init() {
        continuations = []
    }

    package func value() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    package func fulfill(_ result: Result<Value, Error>) {
        guard self.result == nil else {
            return
        }
        self.result = result
        let continuations = self.continuations
        self.continuations = []
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}
