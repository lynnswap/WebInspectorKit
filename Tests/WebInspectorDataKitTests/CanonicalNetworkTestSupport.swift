import Foundation
@testable import WebInspectorDataKit
import WebInspectorProxyKit

struct CanonicalNetworkTestFixture {
    var store: CanonicalNetworkStore
    let storeID: WebInspectorContainerStoreID
    let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    let pageGeneration: WebInspectorPage.Generation

    init(
        storeUUID: UUID = UUID(),
        attachmentGeneration: UInt64 = 1,
        pageGeneration: UInt64 = 1
    ) throws {
        storeID = WebInspectorContainerStoreID(rawValue: storeUUID)
        self.attachmentGeneration =
            WebInspectorContainerAttachmentGeneration(
                rawValue: attachmentGeneration
            )
        self.pageGeneration = WebInspectorPage.Generation(
            rawValue: pageGeneration
        )
        store = CanonicalNetworkStore(storeID: storeID)
        try store.reset(
            attachmentGeneration: self.attachmentGeneration,
            pageGeneration: self.pageGeneration
        )
    }

    func scope(
        targetID: String = "page",
        agentTargetID: String? = nil,
        navigationEpoch: UInt64 = 1,
        domBindingEpoch: UInt64? = nil,
        pageGeneration: WebInspectorPage.Generation? = nil
    ) -> WebInspectorCanonicalNetworkEventScope {
        let semanticTargetID = WebInspectorTarget.ID(targetID)
        let agentTargetID = WebInspectorTarget.ID(
            agentTargetID ?? targetID
        )
        let modelScope = ModelEventScope(
            generation: pageGeneration ?? self.pageGeneration,
            target: ModelTarget(
                id: semanticTargetID,
                kind: .page,
                frameID: nil,
                parentFrameID: nil
            ),
            agentTarget: ModelTarget(
                id: agentTargetID,
                kind: .page,
                frameID: nil,
                parentFrameID: nil
            ),
            navigationEpoch: ModelNavigationEpoch(
                rawValue: navigationEpoch
            ),
            domBindingEpoch: domBindingEpoch.map {
                ModelDOMBindingEpoch(rawValue: $0)
            }
        )
        return WebInspectorCanonicalNetworkEventScope(
            modelScope: modelScope
        )
    }
}

func canonicalRequestWillBeSent(
    id rawID: String,
    url: String,
    method: String = "GET",
    headers: [String: String] = [:],
    postData: String? = nil,
    referrerPolicy: String? = nil,
    integrity: String? = nil,
    backendResourceIdentifier: Network.BackendResourceID? = nil,
    initiatorKind: String = "other",
    initiatorURL: String? = nil,
    initiatorLine: Int? = nil,
    initiatorColumn: Int? = nil,
    initiatorNodeID: String? = nil,
    resourceType: Network.ResourceType? = .fetch,
    redirectResponse: Network.Response? = nil,
    timestamp: Double
) -> Network.Event {
    let id = Network.Request.ID(rawID)
    return .requestWillBeSent(
        id: id,
        request: Network.Request(
            id: id,
            url: url,
            method: method,
            headers: headers,
            postData: postData,
            referrerPolicy: referrerPolicy.map(
                Network.ReferrerPolicy.init(rawValue:)
            ),
            integrity: integrity,
            backendResourceIdentifier: backendResourceIdentifier
        ),
        initiator: Network.Initiator(
            kind: initiatorKind,
            url: initiatorURL,
            line: initiatorLine,
            column: initiatorColumn,
            nodeID: initiatorNodeID.map(DOM.Node.ID.init)
        ),
        resourceType: resourceType,
        redirectResponse: redirectResponse,
        timestamp: timestamp
    )
}
