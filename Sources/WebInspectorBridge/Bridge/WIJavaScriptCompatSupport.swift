package struct WIKUnsafeTransfer<Value>: @unchecked Sendable {
    package let value: Value
}

package enum WIKObjCBlockConversion {
    package static nonisolated func boxingNilAsAnyForCompatibility(
        _ transferredHandler: WIKUnsafeTransfer<(Result<Any, any Error>) -> Void>
    ) -> @Sendable (Any?, (any Error)?) -> Void {
        { value, error in
            if let error {
                transferredHandler.value(.failure(error))
            } else if let value {
                transferredHandler.value(.success(value))
            } else {
                transferredHandler.value(.success(Optional<Any>.none as Any))
            }
        }
    }
}
