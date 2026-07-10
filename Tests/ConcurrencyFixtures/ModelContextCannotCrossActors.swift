import WebInspectorDataKit

func requireSendable<Value: Sendable>(_: Value) {}

func illegallyTreatModelContextAsSendable(
    _ context: WebInspectorModelContext
) {
    requireSendable(context)
}
