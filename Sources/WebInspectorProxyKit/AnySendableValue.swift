package struct AnySendableValue: Sendable {
    package let value: any Sendable

    package init<Value: Sendable>(_ value: Value) {
        self.value = value
    }

    package func cast<Value: Sendable>(
        as type: Value.Type = Value.self
    ) -> Value? {
        value as? Value
    }
}
