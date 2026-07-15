import Testing
@testable import WebInspectorDataKit

@Test
func builtInModelSchemaCatalogIsCompleteUniqueAndFeatureScoped() throws {
    let expectations: [
        Set<WebInspectorFeatureID>: [any WebInspectorPersistentModel.Type]
    ] = [
        []: [],
        [.dom]: [DOMNode.self, CSSStyles.self],
        [.network]: [NetworkRequest.self, NetworkEntry.self],
        [.consoleRuntime]: [ConsoleMessage.self, RuntimeContext.self],
        [.dom, .network, .consoleRuntime]: [
            DOMNode.self,
            CSSStyles.self,
            NetworkRequest.self,
            NetworkEntry.self,
            ConsoleMessage.self,
            RuntimeContext.self,
        ],
    ]

    for (features, expectedModels) in expectations {
        let registry = WebInspectorBuiltInModelSchemas.registry(for: features)
        let modelTypeIDs = registry.schemas.map(\.box.modelTypeID)

        #expect(modelTypeIDs == expectedModels.map(ObjectIdentifier.init))
        #expect(Set(modelTypeIDs).count == modelTypeIDs.count)
        #expect(registry.schemas.allSatisfy { features.contains($0.box.featureID) })
    }
}

@Test
func dynamicModelSchemaCompositionRejectsDuplicateModelTypes() {
    #expect(throws: WebInspectorModelStoreError.self) {
        _ = try WebInspectorModelSchemaRegistry([
            webInspectorDOMNodeSchema.erased,
            webInspectorDOMNodeSchema.erased,
        ])
    }
}
