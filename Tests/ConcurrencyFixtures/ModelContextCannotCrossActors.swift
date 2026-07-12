import WebInspectorDataKit

func requireConcurrencyContextSharing<Value: Sendable>(_: Value) {}

func illegallyShareModelContextAcrossConcurrencyContexts(
    _ context: WebInspectorModelContext
) {
    requireConcurrencyContextSharing(context)
}
