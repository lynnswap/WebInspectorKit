import WebInspectorProxyKit

/// The single composition root for persistent models projected by a model
/// container.
///
/// Registration order is stable and independent of domain acquisition order:
/// DOMNode, NetworkRequest, NetworkEntry, ConsoleMessage, RuntimeContext.
package enum WebInspectorModelSchemaInventory {
    package static func registry(
        configuredDomains: Set<ModelDomain>
    ) -> WebInspectorModelSchemaRegistry {
        let domains = ModelDomain.normalized(configuredDomains)
        var registrations: [WebInspectorModelSchemaRegistration] = []

        if domains.contains(.dom) {
            registrations.append(
                WebInspectorModelSchemaRegistration(.domNode)
            )
        }
        if domains.contains(.network) {
            registrations.append(
                WebInspectorModelSchemaRegistration(
                    WebInspectorNetworkModelSchemas.request
                )
            )
            registrations.append(
                WebInspectorModelSchemaRegistration(
                    WebInspectorNetworkModelSchemas.entry
                )
            )
        }
        if domains.contains(.console) {
            registrations.append(
                WebInspectorModelSchemaRegistration(.consoleMessage)
            )
        }
        if domains.contains(.runtime) {
            registrations.append(
                WebInspectorModelSchemaRegistration(.runtimeContext)
            )
        }

        return WebInspectorModelSchemaRegistry(registrations)
    }
}
