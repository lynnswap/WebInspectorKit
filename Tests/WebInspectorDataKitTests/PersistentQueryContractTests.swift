import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func persistentIdentifiersInferTheirModelAndQueryValueTypes() {
    requirePersistentContract(
        DOMNode.self,
        identifier: DOMNode.ID.self,
        queryValue: DOMNode.QueryValue.self
    )
    requirePersistentContract(
        NetworkRequest.self,
        identifier: NetworkRequest.ID.self,
        queryValue: NetworkRequest.QueryValue.self
    )
    requirePersistentContract(
        ConsoleMessage.self,
        identifier: ConsoleMessage.ID.self,
        queryValue: ConsoleMessage.QueryValue.self
    )
    requirePersistentContract(
        RuntimeContext.self,
        identifier: RuntimeContext.ID.self,
        queryValue: RuntimeContext.QueryValue.self
    )

    #expect(modelTypeIdentifier(for: DOMNode.ID.self) == ObjectIdentifier(DOMNode.self))
    #expect(
        modelTypeIdentifier(for: NetworkRequest.ID.self)
            == ObjectIdentifier(NetworkRequest.self)
    )
    #expect(
        modelTypeIdentifier(for: ConsoleMessage.ID.self)
            == ObjectIdentifier(ConsoleMessage.self)
    )
    #expect(
        modelTypeIdentifier(for: RuntimeContext.ID.self)
            == ObjectIdentifier(RuntimeContext.self)
    )
}

@Test
func modelContextEqualityUsesContextObjectIdentity() {
    let context = WebInspectorModelContext.preview()
    let sameContext = context
    let distinctContext = WebInspectorModelContext.preview()

    #expect(context == sameContext)
    #expect(context != distinctContext)
}

@Test
func modelContextMetatypeIsSendable() {
    requireSendableMetatype(WebInspectorModelContext.self)
}

@Test
func contextLocalResourcesRetainObjectIdentitySemantics() {
    let context = WebInspectorModelContext.preview(
        configuration: .init(domains: [.dom, .css])
    )
    let nodeID = DOMNode.ID(DOM.Node.ID("node"))
    let firstStyles = CSSStyles(nodeID: nodeID, modelContext: context)
    let secondStyles = CSSStyles(nodeID: nodeID, modelContext: context)

    #expect(firstStyles.id == secondStyles.id)
    #expect(firstStyles != secondStyles)
    #expect(Set([firstStyles, firstStyles, secondStyles]).count == 2)

    let objectID = RuntimeObject.ID(synthetic: 1)
    let remoteObject = Runtime.RemoteObject(id: nil, kind: .object)
    let firstObject = RuntimeObject(id: objectID, remoteObject: remoteObject)
    let secondObject = RuntimeObject(id: objectID, remoteObject: remoteObject)

    #expect(firstObject.id == secondObject.id)
    #expect(firstObject != secondObject)
    #expect(Set([firstObject, firstObject, secondObject]).count == 2)
}

@Test
func fetchDescriptorEvaluatesContextuallyTypedPredicateAndSortDescriptor() throws {
    let media = NetworkRequest.ResourceCategory.media
    let get = "GET"
    var descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
        predicate: #Predicate { value in
            value.resourceCategory == media && value.method == get
        },
        sortBy: [SortDescriptor(\.insertionIndex, order: .reverse)]
    )

    let earlier = networkQueryValue(
        id: "earlier",
        insertionIndex: 1,
        method: "GET",
        category: .media
    )
    let later = networkQueryValue(
        id: "later",
        insertionIndex: 2,
        method: "POST",
        category: .media
    )

    let predicate = try #require(descriptor.predicate)
    #expect(try predicate.evaluate(earlier))
    #expect(try predicate.evaluate(later) == false)
    #expect(descriptor.sortBy[0].compare(later, earlier) == .orderedAscending)

    #expect(descriptor.fetchOffset == 0)
    #expect(descriptor.fetchLimit == nil)
    descriptor.fetchOffset = 2
    descriptor.fetchLimit = 0
    #expect(descriptor.fetchOffset == 2)
    #expect(descriptor.fetchLimit == 0)
}

private func requirePersistentContract<Model>(
    _: Model.Type,
    identifier _: Model.ID.Type,
    queryValue _: Model.QueryValue.Type
) where Model: WebInspectorPersistentModel {
    requireSendable(Model.ID.self)
    requireSendable(Model.QueryValue.self)
}

private func requireSendable<Value>(_: Value.Type) where Value: Sendable {}

private func requireSendableMetatype<Value>(
    _: Value.Type
) where Value: SendableMetatype {}

private func modelTypeIdentifier<ID>(
    for _: ID.Type
) -> ObjectIdentifier where ID: WebInspectorPersistentIdentifier {
    ObjectIdentifier(ID.Model.self)
}

private func networkQueryValue(
    id: String,
    insertionIndex: Int,
    method: String,
    category: NetworkRequest.ResourceCategory
) -> NetworkRequest.QueryValue {
    NetworkRequest.QueryValue(
        id: NetworkRequest.ID(Network.Request.ID(id)),
        insertionIndex: insertionIndex,
        url: "https://example.test/\(id)",
        method: method,
        resourceType: category == .media ? .media : .other,
        mimeType: category == .media ? "video/mp4" : "application/octet-stream",
        resourceCategory: category,
        searchableText: id,
        statusCode: 200,
        requestSentTimestamp: Double(insertionIndex),
        initiatorNodeID: nil
    )
}
