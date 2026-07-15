import Foundation
@testable import WebInspectorDataKit
import WebInspectorProxyKit

struct CanonicalNetworkTestFixture {
    var store: CanonicalNetworkStore
    let storeID: WebInspectorContainerStoreID
    let attachmentGeneration: WebInspectorAttachmentGeneration
    let pageGeneration: WebInspectorPageGeneration

    init(
        storeUUID: UUID = UUID(),
        attachmentGeneration: UInt64 = 1,
        pageGeneration: UInt64 = 1
    ) throws {
        storeID = WebInspectorContainerStoreID(rawValue: storeUUID)
        self.attachmentGeneration = WebInspectorAttachmentGeneration(
            rawValue: attachmentGeneration
        )
        self.pageGeneration = WebInspectorPageGeneration(
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
        pageGeneration: WebInspectorPageGeneration? = nil
    ) -> WebInspectorCanonicalNetworkEventScope {
        let semanticTargetID = WebInspectorTarget.ID(targetID)
        let agentTargetID = WebInspectorTarget.ID(
            agentTargetID ?? targetID
        )
        let modelScope = WebInspectorFeatureEventScope(
            generation: pageGeneration ?? self.pageGeneration,
            semanticTarget: WebInspectorFeatureTarget(
                id: semanticTargetID,
                kind: .page,
                frameID: nil
            ),
            agentTarget: WebInspectorFeatureTarget(
                id: agentTargetID,
                kind: .page,
                frameID: nil
            )
        )
        return WebInspectorCanonicalNetworkEventScope(
            modelScope: modelScope,
            origin: .eventTarget(semanticTargetID),
            targetAuthority: CanonicalNetworkRegisteredTargetAuthority(
                targetID: semanticTargetID,
                navigationEpoch: WebInspectorPageGeneration(
                    rawValue: navigationEpoch
                ),
                domBindingEpoch: domBindingEpoch.map {
                    WebInspectorDOMBindingScopeID(rawValue: $0)
                }
            ),
            frameID: FrameID("main-frame"),
            loaderID: "loader"
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
    originFrameID: String? = nil,
    originLoaderID: String = "loader",
    originTargetID: String? = nil,
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
            backendResourceIdentifier: backendResourceIdentifier,
            origin: originFrameID.map { frameID in
                Network.Request.Origin(
                    frameID: FrameID(frameID),
                    loaderID: originLoaderID,
                    targetID: originTargetID
                )
            }
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
