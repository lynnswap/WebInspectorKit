package enum WebInspectorBuiltInModelSchemas {
    package static func registry(
        for enabledFeatures: Set<WebInspectorFeatureID>
    ) -> WebInspectorModelSchemaRegistry {
        var schemas: [WebInspectorAnyModelSchema] = []
        if enabledFeatures.contains(.dom) {
            schemas.append(webInspectorDOMNodeSchema.erased)
            schemas.append(webInspectorCSSStylesSchema.erased)
        }
        if enabledFeatures.contains(.network) {
            schemas.append(webInspectorNetworkRequestSchema.erased)
            schemas.append(webInspectorNetworkEntrySchema.erased)
        }
        if enabledFeatures.contains(.consoleRuntime) {
            schemas.append(webInspectorConsoleMessageSchema.erased)
            schemas.append(webInspectorRuntimeContextSchema.erased)
        }
        return .builtIn(schemas)
    }
}
